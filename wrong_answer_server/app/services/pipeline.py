"""
两阶段流水线编排（由异步任务调用）
Stage 1: MinerU OCR → content_blocks（0~1000 坐标系）
Stage 2: Qwen2.5-VL 语义分析（条件触发）+ 手写答案区识别

对外暴露两个函数：
- run_upload()  : Stage1，parse 任务体
- run_extract() : 筛选+Stage2+Asset 提取，extract 任务体
"""
from __future__ import annotations
import json
import logging
import time
import uuid
from pathlib import Path

import cv2

from app.config import settings
from app.models.schema import (
    WrongAnswerRecord, Source, UserSelection, Region,
    Asset, ErrorAnalysis, ContentBlock,
    UploadResponse, ExtractResponse,
)
from app.core import mineru_client, qwen_client, asset_extractor
from app.core.runlog import RunLog

logger = logging.getLogger(__name__)


# ── 全页解析（parse 任务）────────────────────────────────────────────────────

async def run_upload(
    original_path: Path,
    image_source: str = "camera",
) -> UploadResponse:
    """
    Stage1：原图 MinerU 全页解析。
    返回 content_blocks 预览（bbox 0~1000）供 Flutter 绘制覆盖层。
    """
    blocks, _ = await mineru_client.parse_image(original_path)

    img = cv2.imread(str(original_path))
    if img is None:
        raise ValueError(f"无法读取原图: {original_path}")
    height, width = img.shape[:2]

    preview = [
        ContentBlock(id=b.id, type=b.type, content="", bbox=b.bbox)
        for b in blocks
    ]

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


# ── ROI 提取（extract 任务）──────────────────────────────────────────────────

async def run_extract(
    image_id: str,
    originals_dir: Path,
    question_region: Region,
    answer_region: Region | None = None,
    image_source: str = "camera",
    enable_semantic: bool = True,
) -> ExtractResponse:
    """
    从缓存 blocks 筛选题区 → Qwen 语义分析（可附带手写答案区文本）
    → Asset 裁切 → 组装记录。
    """
    t0 = time.perf_counter()
    debug_info: dict = {}
    record_id = str(uuid.uuid4())
    runlog = RunLog(record_id)

    original_path = _find_original(originals_dir, image_id)
    blocks, original_size = _load_cached_blocks(originals_dir, image_id)

    if not blocks:
        logger.warning(f"blocks 缓存未命中，重新解析: {image_id}")
        blocks, _ = await mineru_client.parse_image(original_path)
        img = cv2.imread(str(original_path))
        _h, _w = img.shape[:2]
        original_size = [_w, _h]

    # ── 区域坐标 → 0~1000 ────────────────────────────────────────────────────
    q_bbox = _region_to_1000(question_region, original_size)
    q_pixels = _bbox_1000_to_pixels(q_bbox, original_size)
    logger.info(f"题区 0~1000: {[round(v, 1) for v in q_bbox]}")

    # ── ROI 筛选 ──────────────────────────────────────────────────
    filtered = mineru_client.filter_blocks_by_roi(blocks, q_bbox)
    ocr_text = mineru_client.blocks_to_text(filtered)
    runlog.stage(
        "ocr", "mineru", "MinerU-4.0",
        [b.model_dump() for b in filtered], ocr_text,
    )
    logger.info(f"OCR 文本({len(ocr_text)}字): '{ocr_text[:200]}'")

    # ── Vision fallback：OCR 为空时裁切题区原图直接送 Qwen Vision ────────────
    vision_fallback_used = False
    extra_figures: list[ContentBlock] = []
    if not ocr_text.strip():
        logger.warning("MinerU OCR 返回空文本，启动 Vision fallback")
        try:
            ocr_text, extra_figures = await _vision_fallback(
                original_path, q_pixels, original_size, runlog
            )
            vision_fallback_used = True
        except Exception as e:
            logger.error(f"Vision fallback 失败: {e}")
            ocr_text = ""

    debug_info["ocr_text"] = ocr_text
    debug_info["filtered_block_count"] = len(filtered)
    debug_info["vision_fallback_used"] = vision_fallback_used

    # ── 手写答案区识别（可选）─────────────────────────────────────────────────
    student_answer = ""
    if answer_region is not None and answer_region.bbox:
        a_bbox = _region_to_1000(answer_region, original_size)
        a_pixels = _bbox_1000_to_pixels(a_bbox, original_size)
        try:
            crop_path = _crop_to_file(original_path, a_pixels, record_id, "answer")
            answer_region.image_path = str(
                crop_path.relative_to(settings.storage_root)
            )
            student_answer = (await qwen_client.ocr_image(crop_path)).strip()
            answer_region.text = student_answer
            runlog.stage(
                "handwriting_ocr", "vllm", settings.qwen_model_name,
                None, student_answer, {"region": a_bbox},
            )
        except Exception as e:
            logger.error(f"手写答案区识别失败: {e}")

    # ── figure 资源提取 ───────────────────────────────────────────────────
    figure_blocks = [b for b in filtered if b.type in ("figure", "image")]
    figure_blocks.extend(extra_figures)

    assets: list[Asset] = asset_extractor.extract_assets(
        original_path, figure_blocks, record_id, original_size=original_size
    )

    # ── 语义分析（Qwen）──────────────────────────────────────────────────
    semantic: dict = {}
    if enable_semantic and ocr_text.strip():
        try:
            semantic = await qwen_client.analyze_semantic(ocr_text, student_answer or None)
            runlog.stage(
                "semantic", "vllm", settings.qwen_model_name,
                {"ocr_text": ocr_text, "student_answer": student_answer}, semantic,
            )
        except Exception as e:
            logger.error(f"Qwen 语义分析失败: {e}")
            semantic = {}

    # ── 组装 problem_md：题干 + 选项（选择题）───────────────────────────
    problem_stem = semantic.get("problem", ocr_text)
    options: list[str] = semantic.get("options", [])

    if options:
        problem_md = problem_stem + "\n\n" + "\n".join(options)
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
        page_width_px=original_size[0],
        page_height_px=original_size[1],
        user_selection=UserSelection(roi_bbox=q_pixels),
    )

    error_data = semantic.get("error_analysis", {})
    error_analysis = ErrorAnalysis(
        student_answer=error_data.get("student_answer") or student_answer,
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
    runlog.flush()

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
    cache_path = originals_dir / f"{image_id}_blocks.json"
    if not cache_path.exists():
        return [], [0, 0]
    data = json.loads(cache_path.read_text(encoding="utf-8"))

    if isinstance(data, list):  # 旧格式缓存（无 original_size），强制重解析
        return [], [0, 0]

    blocks = [ContentBlock(**b) for b in data["blocks"]]
    original_size = data.get("original_size", [0, 0])
    if original_size[0] == 0 or original_size[1] == 0:
        return [], [0, 0]
    return blocks, original_size


def _region_to_1000(region: Region, original_size: list[int]) -> list[float]:
    """任意 coord_space 的区域 → 0~1000 坐标系。"""
    if region.coord_space == "0_1000":
        return list(region.bbox[:4])
    ow, oh = original_size
    if ow == 0 or oh == 0:
        raise ValueError("缺少原图尺寸，无法映射 pixel 坐标")
    x1, y1, x2, y2 = region.bbox[:4]
    return [x1 / ow * 1000, y1 / oh * 1000, x2 / ow * 1000, y2 / oh * 1000]


def _bbox_1000_to_pixels(bbox: list[float], original_size: list[int]) -> list[int]:
    ow, oh = original_size
    return [
        int(bbox[0] / 1000 * ow),
        int(bbox[1] / 1000 * oh),
        int(bbox[2] / 1000 * ow),
        int(bbox[3] / 1000 * oh),
    ]


def _crop_to_file(
    original_path: Path, px_bbox: list[int], record_id: str, name: str
) -> Path:
    """按像素 bbox 裁切原图，保存到 rois/{record_id}/{name}.png"""
    img = cv2.imread(str(original_path))
    if img is None:
        raise ValueError(f"无法读取原图: {original_path}")
    h, w = img.shape[:2]
    x1, y1, x2, y2 = px_bbox
    x1, y1 = max(0, x1), max(0, y1)
    x2, y2 = min(w, x2), min(h, y2)
    if x2 <= x1 or y2 <= y1:
        raise ValueError(f"裁切区域无效: {px_bbox}")
    cropped = img[y1:y2, x1:x2]
    dst = settings.rois_dir / record_id / f"{name}.png"
    dst.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(dst), cropped)
    return dst


async def _vision_fallback(
    original_path: Path,
    q_pixels: list[int],
    original_size: list[int],
    runlog: RunLog | None = None,
) -> tuple[str, list[ContentBlock]]:
    """
    Vision fallback：MinerU OCR 为空时，裁切题区原图送 Qwen Vision 识别，
    并用 visual grounding 补充检测插图。
    """
    img = cv2.imread(str(original_path))
    if img is None:
        raise ValueError(f"无法读取原图: {original_path}")

    ow, oh = original_size
    pad = 20
    x1 = max(0, q_pixels[0] - pad)
    y1 = max(0, q_pixels[1] - pad)
    x2 = min(ow, q_pixels[2] + pad)
    y2 = min(oh, q_pixels[3] + pad)

    cropped = img[y1:y2, x1:x2]
    if cropped.size == 0:
        raise ValueError("裁切区域为空")

    crop_path = _crop_to_file(original_path, [x1, y1, x2, y2], "vision_fallback", "roi")
    try:
        ocr_text = await qwen_client.ocr_image(crop_path)
        if runlog:
            runlog.stage(
                "vision_fallback_ocr", "vllm", settings.qwen_model_name,
                None, ocr_text,
            )
        try:
            detections = await qwen_client.detect_figures_in_image(crop_path)
        except Exception as e:
            logger.warning(f"Visual grounding 插图检测失败: {e}")
            detections = []
    finally:
        crop_path.unlink(missing_ok=True)

    # 检测框（裁切图内像素坐标）映射回原图 0~1000 坐标系
    extra_figures: list[ContentBlock] = []
    for i, det in enumerate(detections):
        bbox_2d = det.get("bbox_2d", [])
        if len(bbox_2d) != 4:
            continue
        cx1, cy1, cx2, cy2 = (float(v) for v in bbox_2d)
        mapped_bbox = [
            (x1 + cx1) / ow * 1000,
            (y1 + cy1) / oh * 1000,
            (x1 + cx2) / ow * 1000,
            (y1 + cy2) / oh * 1000,
        ]
        extra_figures.append(ContentBlock(
            id=f"qwen_fig_{i}",
            type="figure",
            content=det.get("label", "插图"),
            bbox=mapped_bbox,
        ))

    logger.info(
        f"Vision fallback 完成: 文本 {len(ocr_text)} 字, 插图 {len(extra_figures)} 个"
    )
    return ocr_text, extra_figures
