"""
两阶段流水线编排
Stage 1: MinerU OCR → content_blocks
Stage 2: Qwen2.5-VL 语义分析（条件触发）

对外暴露两个函数：
- run_upload()   : Stage1，用于 /api/v1/upload
- run_extract()  : Stage1+ROI筛选+Stage2+Asset提取，用于 /api/v1/extract

修改记录：
  v1.1 - 新增 Vision fallback：当 MinerU OCR 返回空文本时，
          自动裁切 ROI 原图直接送 Qwen Vision 识别。
  v1.2 - 修复选择题选项丢失：
          Qwen 现在返回独立的 options 字段（字符串数组）。
          pipeline 在组装 problem_md 时，将 options 追加到题干后面，
          前端显示的 problem 字段即为完整的"题干 + 选项"内容，
          不需要修改前端渲染逻辑。
"""
from __future__ import annotations
import time
import logging
from pathlib import Path

from app.config import settings
from app.models.schema import (
    WrongAnswerRecord, Source, UserSelection,
    Asset, ErrorAnalysis, ContentBlock,
    UploadResponse, ExtractResponse,
)
from app.core import mineru_client, qwen_client, asset_extractor

logger = logging.getLogger(__name__)


# ── 全页解析（/upload 阶段）─────────────────────────────────────────────────

async def run_upload(
    original_path: Path,
    image_source: str = "camera",
) -> UploadResponse:
    """
    Stage1：原图 MinerU 全页解析。
    返回 content_blocks 预览供 Flutter 绘制 ROI 覆盖层。
    """
    t0 = time.perf_counter()

    blocks, min_conf = await mineru_client.parse_image(original_path)

    import cv2
    img = cv2.imread(str(original_path))
    height, width = img.shape[:2]

    logger.info(f"原图尺寸: {width}x{height}, blocks={len(blocks)}")

    elapsed = int((time.perf_counter() - t0) * 1000)
    logger.info(f"run_upload 完成: {elapsed}ms, {len(blocks)} blocks, conf={min_conf:.3f}")

    preview = [
        ContentBlock(id=b.id, type=b.type, content="", bbox=b.bbox)
        for b in blocks
    ]

    import json
    cache_path = original_path.parent / f"{original_path.stem}_blocks.json"
    cache_path.write_text(
        json.dumps({
            "blocks": [b.model_dump() for b in blocks],
            "original_size": [width, height],
        }, ensure_ascii=False),
        encoding="utf-8",
    )

    return UploadResponse(
        image_id=original_path.stem,
        width_px=width,
        height_px=height,
        preview_blocks=preview,
    )


# ── ROI 提取（/extract 阶段）────────────────────────────────────────────────

async def run_extract(
    image_id: str,
    originals_dir: Path,
    roi_bbox: list[float],
    image_source: str = "camera",
    enable_semantic: bool = True,
) -> ExtractResponse:
    """
    Stage2：从缓存 blocks 筛选 ROI → Qwen 语义分析 → Asset 裁切 → 组装记录

    v1.2 变化：
    - Qwen 返回的 options 字段追加到 problem_md，前端无需改动即可显示完整题目。
    - 追加格式：每个选项占一行，与题干之间空一行。
    """
    t0 = time.perf_counter()
    debug_info: dict = {}

    # ── 找到原图和缓存 blocks ─────────────────────────────────────────────
    original_path = _find_original(originals_dir, image_id)
    blocks, original_size = _load_cached_blocks(originals_dir, image_id)

    if not blocks:
        logger.warning(f"blocks 缓存未命中，重新解析: {image_id}")
        blocks, _ = await mineru_client.parse_image(original_path)
        import cv2 as _cv2
        _img = _cv2.imread(str(original_path))
        _h, _w = _img.shape[:2]
        original_size = [_w, _h]

    # ── ROI 坐标映射 ──────────────────────────────────────────────────────
    mapped_roi = _remap_roi(roi_bbox, original_size)
    logger.info(
        f"ROI 坐标映射: 原图{original_size} → MinerU 0~1000, "
        f"原始ROI={[round(v,1) for v in roi_bbox]}, "
        f"映射后ROI={[round(v,1) for v in mapped_roi]}"
    )

    # ── ROI 筛选 ──────────────────────────────────────────────────────────
    filtered = mineru_client.filter_blocks_by_roi(blocks, mapped_roi)
    for b in filtered:
        logger.info(f"  筛选到 block: id={b.id} type={b.type} content='{b.content[:60]}' bbox={b.bbox}")
    ocr_text = mineru_client.blocks_to_text(filtered)
    logger.info(f"OCR 文本({len(ocr_text)}字): '{ocr_text[:200]}'")

    # ── Vision fallback：OCR 为空时裁切 ROI 原图直接送 Qwen Vision ────────
    vision_fallback_used = False
    extra_figures: list[ContentBlock] = []
    if not ocr_text.strip():
        logger.warning("MinerU OCR 返回空文本，启动 Vision fallback")
        try:
            ocr_text, extra_figures = await _vision_fallback(
                original_path, roi_bbox, original_size
            )
            vision_fallback_used = True
            logger.info(
                f"Vision fallback 完成，识别文本({len(ocr_text)}字), "
                f"检测到插图({len(extra_figures)}个)"
            )
        except Exception as e:
            logger.error(f"Vision fallback 失败: {e}")
            ocr_text = ""

    debug_info["ocr_text"] = ocr_text
    debug_info["filtered_block_count"] = len(filtered)
    debug_info["vision_fallback_used"] = vision_fallback_used

    # ── figure 资源提取 ───────────────────────────────────────────────────
    import uuid
    record_id = str(uuid.uuid4())
    figure_blocks = [b for b in filtered if b.type in ("figure", "image")]

    # 将 Qwen visual grounding 检测到的插图追加到 figure_blocks
    if extra_figures:
        figure_blocks.extend(extra_figures)
        logger.info(f"追加 {len(extra_figures)} 个 Qwen 检测到的插图到 figure_blocks")

    assets: list[Asset] = asset_extractor.extract_assets(
        original_path, figure_blocks, record_id, original_size=original_size
    )

    # ── 语义分析（Qwen）──────────────────────────────────────────────────
    semantic: dict = {}
    if enable_semantic and ocr_text.strip():
        try:
            semantic = await qwen_client.analyze_semantic(ocr_text)
            debug_info["semantic_raw"] = semantic
        except Exception as e:
            logger.error(f"Qwen 语义分析失败: {e}")
            semantic = {}

    # ── 组装 problem_md：题干 + 选项（选择题）───────────────────────────
    # Qwen v1.2 起会返回独立的 options 字段。
    # 此处将 options 追加到 problem 末尾，前端显示的 problem 字段即为完整题目，
    # 无需前端做任何格式拼接。
    problem_stem = semantic.get("problem", ocr_text)
    options: list[str] = semantic.get("options", [])

    if options:
        options_md = "\n\n" + "\n".join(options)
        problem_md = problem_stem + options_md
        logger.info(f"选择题：追加 {len(options)} 个选项到 problem_md")
    else:
        problem_md = problem_stem

    solution_md = semantic.get("solution", "")

    if assets:
        problem_md = asset_extractor.inject_assets_into_markdown(problem_md, assets)
        solution_md = asset_extractor.inject_assets_into_markdown(solution_md, assets)

    # ── 组装 WrongAnswerRecord ────────────────────────────────────────────
    source = Source(
        image_path=str(original_path.relative_to(originals_dir.parent)),
        image_source=image_source,  # type: ignore[arg-type]
        page_width_px=0,
        page_height_px=0,
        user_selection=UserSelection(roi_bbox=roi_bbox),
    )

    error_data = semantic.get("error_analysis", {})
    error_analysis = ErrorAnalysis(
        student_answer=error_data.get("student_answer", ""),
        error_category=error_data.get("error_category", "未知"),  # type: ignore
        error_desc=error_data.get("error_desc", ""),
        prevention_tip=error_data.get("prevention_tip", ""),
    )

    record = WrongAnswerRecord(
        id=record_id,
        source=source,
        type=semantic.get("type", "未知"),
        seq=semantic.get("seq"),
        sub_seq=semantic.get("sub_seq"),
        problem=problem_md,
        answer=semantic.get("answer", ""),
        solution=solution_md,
        assets=assets,
        subject=semantic.get("subject", "未知"),
        grade=semantic.get("grade", "未知"),
        chapters=semantic.get("chapters", []),
        knowledge_points=semantic.get("knowledge_points", []),
        key_points=semantic.get("key_points", []),
        difficulty=semantic.get("difficulty", 3),
        difficulty_desc=semantic.get("difficulty_desc", ""),
        error_analysis=error_analysis,
        tags=semantic.get("tags", []),
    )

    elapsed = int((time.perf_counter() - t0) * 1000)
    logger.info(f"run_extract 完成: {elapsed}ms, record_id={record_id}")

    return ExtractResponse(
        record=record,
        debug=debug_info if settings.debug else None,
    )


# ── 工具函数 ──────────────────────────────────────────────────────────────────

def _find_original(originals_dir: Path, image_id: str) -> Path:
    for ext in (".jpg", ".jpeg", ".png", ".webp"):
        p = originals_dir / f"{image_id}{ext}"
        if p.exists():
            return p
    raise FileNotFoundError(f"原图未找到: {originals_dir}/{image_id}.*")


def _load_cached_blocks(
    originals_dir: Path, image_id: str
) -> tuple[list[ContentBlock], list[int]]:
    import json
    cache_path = originals_dir / f"{image_id}_blocks.json"
    if not cache_path.exists():
        return [], [0, 0]
    data = json.loads(cache_path.read_text(encoding="utf-8"))

    if isinstance(data, list):
        blocks = [ContentBlock(**b) for b in data]
        return blocks, [0, 0]

    blocks = [ContentBlock(**b) for b in data["blocks"]]
    original_size = data.get("original_size", [0, 0])
    return blocks, original_size


def _remap_roi(
    roi: list[float],
    original_size: list[int],
) -> list[float]:
    """
    将客户端 ROI（原图像素坐标）映射到 MinerU content_list 0~1000 坐标系。
    """
    ow, oh = original_size
    if ow == 0 or oh == 0:
        return roi
    x1, y1, x2, y2 = roi[:4]
    return [
        x1 / ow * 1000,
        y1 / oh * 1000,
        x2 / ow * 1000,
        y2 / oh * 1000,
    ]


async def _vision_fallback(
    original_path: Path,
    roi_bbox: list[float],
    original_size: list[int],
) -> tuple[str, list[ContentBlock]]:
    """
    Vision fallback：MinerU OCR 为空时，裁切 ROI 原图送 Qwen Vision 识别。

    返回: (ocr_text, extra_figure_blocks)
    extra_figure_blocks 是 Qwen visual grounding 检测到的插图，用于补充
    MinerU 未检测到的 figure。
    """
    import cv2
    import tempfile

    img = cv2.imread(str(original_path))
    if img is None:
        logger.error(f"Vision fallback：无法读取原图 {original_path}")
        return "", []

    ow, oh = original_size
    roi_x1, roi_y1, roi_x2, roi_y2 = (int(v) for v in roi_bbox[:4])
    pad = 20
    x1 = max(0, roi_x1 - pad)
    y1 = max(0, roi_y1 - pad)
    x2 = min(ow, roi_x2 + pad)
    y2 = min(oh, roi_y2 + pad)

    cropped = img[y1:y2, x1:x2]
    if cropped.size == 0:
        logger.error("Vision fallback：裁切区域为空")
        return "", []

    logger.info(f"Vision fallback：裁切区域 ({x1},{y1})-({x2},{y2})，尺寸 {x2-x1}x{y2-y1}")

    tmp_path = None
    ocr_text = ""
    detections: list[dict] = []

    try:
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
            tmp_path = Path(tmp.name)
        cv2.imwrite(str(tmp_path), cropped, [cv2.IMWRITE_JPEG_QUALITY, 95])

        # 1. OCR 识别文字
        ocr_text = await qwen_client.ocr_image(tmp_path)

        # 2. Visual Grounding 检测插图（在临时文件删除前完成）
        try:
            detections = await qwen_client.detect_figures_in_image(tmp_path)
        except Exception as e:
            logger.warning(f"Visual grounding 插图检测失败: {e}")

    finally:
        if tmp_path and tmp_path.exists():
            tmp_path.unlink(missing_ok=True)

    # 3. 将检测到的 bbox 映射回原图坐标系，构造 ContentBlock
    extra_figures: list[ContentBlock] = []
    for i, det in enumerate(detections):
        bbox_2d = det.get("bbox_2d", [])
        if len(bbox_2d) != 4:
            continue

        cx1, cy1, cx2, cy2 = (float(v) for v in bbox_2d)

        # 映射回原图绝对像素坐标
        orig_x1 = x1 + cx1
        orig_y1 = y1 + cy1
        orig_x2 = x1 + cx2
        orig_y2 = y1 + cy2

        # 转换为 0~1000 归一化坐标（与 MinerU 返回的 ContentBlock.bbox 坐标系一致）
        mapped_bbox = [
            orig_x1 / ow * 1000,
            orig_y1 / oh * 1000,
            orig_x2 / ow * 1000,
            orig_y2 / oh * 1000,
        ]

        extra_figures.append(ContentBlock(
            id=f"qwen_fig_{i}",
            type="figure",
            content=det.get("label", "插图"),
            bbox=mapped_bbox,
            asset_path=None,
            score=None,
        ))
        logger.info(
            f"Qwen 检测到插图: label={det.get('label')}, "
            f"roi_bbox=[{cx1:.0f},{cy1:.0f},{cx2:.0f},{cy2:.0f}], "
            f"orig_bbox=[{orig_x1:.0f},{orig_y1:.0f},{orig_x2:.0f},{orig_y2:.0f}]"
        )

    return ocr_text, extra_figures


def _clean_latex(text: str) -> str:
    """清理 Qwen 返回的 LaTeX 中的多余转义字符"""
    if not text:
        return text
    text = text.replace("\\n", "\n")
    import re
    text = re.sub(r"\\text\{", "", text)
    text = text.replace("}\\", "}")
    return text