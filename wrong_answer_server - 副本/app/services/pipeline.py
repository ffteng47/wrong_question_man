"""
两阶段流水线编排
Stage 1: MinerU OCR → content_blocks
Stage 2: Qwen2.5-VL 语义分析（条件触发）

对外暴露两个函数：
- run_upload()   : Stage1，用于 /api/v1/upload
- run_extract()  : Stage1+ROI筛选+Stage2+Asset提取，用于 /api/v1/extract
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
from app.core.preprocess import preprocess_image

logger = logging.getLogger(__name__)


# ── 全页解析（/upload 阶段）─────────────────────────────────────────────────

async def run_upload(
    original_path: Path,
    image_source: str = "camera",
) -> UploadResponse:
    """
    Stage1：预处理 + MinerU 全页解析。
    返回 content_blocks 预览供 Flutter 绘制 ROI 覆盖层。
    """
    t0 = time.perf_counter()

    # 预处理
    processed_path = original_path.parent / f"proc_{original_path.name}"
    _, width, height = preprocess_image(original_path, processed_path, image_source)

    # MinerU 解析
    blocks, min_conf = await mineru_client.parse_image(processed_path)

    elapsed = int((time.perf_counter() - t0) * 1000)
    logger.info(f"run_upload 完成: {elapsed}ms, {len(blocks)} blocks, conf={min_conf:.3f}")

    # 预览 blocks 只返回 id/type/bbox（减少传输量）
    preview = [
        ContentBlock(id=b.id, type=b.type, content="", bbox=b.bbox)
        for b in blocks
    ]

    # 把完整 blocks 缓存在内存（按 image_id），供 extract 阶段复用
    # 简单实现：写到临时 JSON 文件（避免引入 Redis）
    import json
    cache_path = original_path.parent / f"{original_path.stem}_blocks.json"
    cache_path.write_text(
        json.dumps([b.model_dump() for b in blocks], ensure_ascii=False),
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
    """
    t0 = time.perf_counter()
    debug_info: dict = {}

    # ── 找到原图和缓存 blocks ─────────────────────────────────────────────
    original_path = _find_original(originals_dir, image_id)
    blocks = _load_cached_blocks(originals_dir, image_id)

    # 若缓存 miss，重新解析（降级）
    if not blocks:
        logger.warning(f"blocks 缓存未命中，重新解析: {image_id}")
        processed_path = original_path.parent / f"proc_{original_path.name}"
        if not processed_path.exists():
            preprocess_image(original_path, processed_path, image_source)
        blocks, _ = await mineru_client.parse_image(processed_path)

    # ── ROI 筛选 ──────────────────────────────────────────────────────────
    filtered = mineru_client.filter_blocks_by_roi(blocks, roi_bbox)
    ocr_text = mineru_client.blocks_to_text(filtered)

    debug_info["ocr_text"] = ocr_text
    debug_info["filtered_block_count"] = len(filtered)

    # ── figure 资源提取 ───────────────────────────────────────────────────
    import uuid
    record_id = str(uuid.uuid4())
    figure_blocks = [b for b in filtered if b.type in ("figure", "image")]
    assets: list[Asset] = asset_extractor.extract_assets(
        original_path, figure_blocks, record_id
    )

    # ── 语义分析（Qwen）──────────────────────────────────────────────────
    semantic: dict = {}
    if enable_semantic and ocr_text.strip():
        try:
            semantic = await qwen_client.analyze_semantic(ocr_text)
            debug_info["semantic_raw"] = semantic
        except Exception as e:
            logger.error(f"Qwen 语义分析失败: {e}")
            # 降级：返回纯 OCR 结果，不抛出异常
            semantic = {}

    # ── 组装 WrongAnswerRecord ────────────────────────────────────────────
    source = Source(
        image_path=str(original_path.relative_to(originals_dir.parent)),
        image_source=image_source,  # type: ignore[arg-type]
        page_width_px=0,
        page_height_px=0,
        user_selection=UserSelection(roi_bbox=roi_bbox),
    )

    # 注入 assets 到 Markdown 文本
    problem_md = semantic.get("problem", ocr_text)
    solution_md = semantic.get("solution", "")
    if assets:
        problem_md = asset_extractor.inject_assets_into_markdown(problem_md, assets)
        solution_md = asset_extractor.inject_assets_into_markdown(solution_md, assets)

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
    """按 image_id（stem）找原图，支持 jpg/jpeg/png"""
    for ext in (".jpg", ".jpeg", ".png", ".webp"):
        p = originals_dir / f"{image_id}{ext}"
        if p.exists():
            return p
    raise FileNotFoundError(f"原图未找到: {originals_dir}/{image_id}.*")


def _load_cached_blocks(originals_dir: Path, image_id: str) -> list[ContentBlock]:
    """读取 run_upload 写入的 blocks 缓存"""
    import json
    cache_path = originals_dir / f"{image_id}_blocks.json"
    if not cache_path.exists():
        return []
    data = json.loads(cache_path.read_text(encoding="utf-8"))
    return [ContentBlock(**b) for b in data]
