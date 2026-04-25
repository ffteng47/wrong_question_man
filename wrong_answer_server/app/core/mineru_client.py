"""
MinerU API 客户端
- 调用 mineru-api 官方 FastAPI（POST /file_parse）
- 解析返回的 content_list
- 提供 IoU 筛选 ROI 内的 blocks
"""
from __future__ import annotations
import httpx
import json
import logging
from pathlib import Path
from app.config import settings
from app.models.schema import ContentBlock

logger = logging.getLogger(__name__)

# MinerU API 超时（大图解析可能需要 5-10s）
_TIMEOUT = httpx.Timeout(180.0, connect=10.0)


def _map_mineru_type(mineru_type: str) -> str:
    """将 MinerU content_list 的 type 映射到 ContentBlock 的 type"""
    mapping = {
        "text": "text",
        "title": "title",
        "image": "figure",
        "figure": "figure",
        "table": "table",
        "equation": "formula",
        "formula": "formula",
        "interline_equation": "formula",
        "inline_equation": "formula",
    }
    return mapping.get(mineru_type, "text")


async def parse_image(image_path: Path) -> tuple[list[ContentBlock], float]:
    """
    调用 MinerU 官方 /file_parse 解析单张图片。
    返回 (content_blocks, min_confidence)。
    """
    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        with open(image_path, "rb") as f:
            resp = await client.post(
                f"{settings.mineru_base_url}/file_parse",
                files={
                    "files": (
                        image_path.name,
                        f,
                        "application/octet-stream",
                    )
                },
                data={
                    "return_md": "false",
                    "return_content_list": "true",
                    "return_images": "false",
                    "response_format_zip": "false",
                    "backend": "pipeline",
                    "parse_method": "ocr",
                },
            )
        resp.raise_for_status()
        data = resp.json()

    if settings.debug:
        logger.debug(f"[MinerU raw] keys={list(data.keys())}")

    # ── 解析 results ─────────────────────────────────────────────────────────
    results = data.get("results", {})
    if not results:
        logger.warning("MinerU /file_parse 返回空 results")
        return [], 1.0

    # 取第一个（也是唯一一个）文件的结果
    file_result = next(iter(results.values()))

    # content_list 是 JSON 字符串
    content_list_raw = file_result.get("content_list", "[]")
    if isinstance(content_list_raw, str):
        raw_blocks: list[dict] = json.loads(content_list_raw)
    else:
        raw_blocks = content_list_raw

    blocks: list[ContentBlock] = []
    for i, blk in enumerate(raw_blocks):
        # MinerU content_list 格式：
        # { "type": "text", "text": "...", "page_idx": 0, "bbox": [x1, y1, x2, y2] }
        bbox = blk.get("bbox", [])
        if isinstance(bbox, list) and len(bbox) >= 4:
            bbox = [float(v) for v in bbox[:4]]
        else:
            bbox = []

        content = blk.get("text", blk.get("content", ""))
        blk_type = _map_mineru_type(blk.get("type", "text"))

        # equation 类型的 content 可能是 LaTeX
        latex = content if blk_type == "formula" else None

        blocks.append(ContentBlock(
            id=f"blk_{i}",
            type=blk_type,
            content=content,
            bbox=bbox,
            latex=latex,
            score=None,  # content_list 中没有置信度
        ))

    # content_list 中没有全局置信度，返回默认值
    min_conf = 1.0
    logger.info(f"MinerU 解析完成: {len(blocks)} blocks, min_conf={min_conf:.3f}")
    return blocks, min_conf


def filter_blocks_by_roi(
    blocks: list[ContentBlock],
    roi_bbox: list[float],
    iou_threshold: float | None = None,
) -> list[ContentBlock]:
    """
    筛选与 ROI 重叠的 blocks（IoU > threshold）。
    同时自动向上注入最近的 title/大题 block 作为上下文。
    """
    threshold = iou_threshold or settings.roi_iou_threshold
    roi = roi_bbox  # [x1, y1, x2, y2]

    filtered: list[ContentBlock] = []
    last_title: ContentBlock | None = None

    for blk in blocks:
        if blk.type in ("title",):
            last_title = blk  # 持续记录最新 title，不管是否在 ROI 内

        if not blk.bbox or len(blk.bbox) < 4:
            continue

        iou = _iob(blk.bbox, roi)
        if iou >= threshold:
            filtered.append(blk)

    # 如果 ROI 内没有 title block 但找到了 last_title，注入作为大题上下文
    has_title_in_roi = any(b.type == "title" for b in filtered)
    if not has_title_in_roi and last_title is not None:
        filtered.insert(0, last_title)
        logger.debug(f"自动注入 title block: '{last_title.content[:40]}'")

    logger.info(f"ROI 筛选: {len(filtered)} blocks 保留（roi={roi}, threshold={threshold}）")
    return filtered


def blocks_to_text(blocks: list[ContentBlock]) -> str:
    """将 content_blocks 拼接为纯文本，供 Qwen 输入"""
    parts = []
    for blk in blocks:
        if blk.type == "formula" and blk.latex:
            parts.append(f"${blk.latex}$")
        elif blk.type == "figure":
            parts.append(f"[图片: {blk.asset_path or 'unknown'}]")
        elif blk.content:
            parts.append(blk.content)
    return "\n".join(parts)


def _iob(a: list[float], b: list[float]) -> float:
    """
    计算 Intersection over Block（交集 / block 自身面积）。
    bbox 格式 [x1, y1, x2, y2]，a 为 block，b 为 ROI。

    用 IoB 而非 IoU 的原因：ROI 通常远大于单个 block，
    若用 IoU（交集/并集）则即使 block 完全在 ROI 内，
    IoU 值也会因 ROI 面积巨大而远低于阈值，导致全部过滤。
    IoB = 交集面积 / block 面积，block 完全在 ROI 内时 = 1.0。
    """
    ax1, ay1, ax2, ay2 = a[:4]
    bx1, by1, bx2, by2 = b[:4]

    inter_x1 = max(ax1, bx1)
    inter_y1 = max(ay1, by1)
    inter_x2 = min(ax2, bx2)
    inter_y2 = min(ay2, by2)

    inter_w = max(0.0, inter_x2 - inter_x1)
    inter_h = max(0.0, inter_y2 - inter_y1)
    inter_area = inter_w * inter_h

    area_a = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1)  # block 自身面积

    return inter_area / area_a if area_a > 0 else 0.0


def _iou(a: list[float], b: list[float]) -> float:
    """计算两个 bbox 的 IoU，bbox 格式 [x1, y1, x2, y2]（保留备用）"""
    ax1, ay1, ax2, ay2 = a[:4]
    bx1, by1, bx2, by2 = b[:4]

    inter_x1 = max(ax1, bx1)
    inter_y1 = max(ay1, by1)
    inter_x2 = min(ax2, bx2)
    inter_y2 = min(ay2, by2)

    inter_w = max(0.0, inter_x2 - inter_x1)
    inter_h = max(0.0, inter_y2 - inter_y1)
    inter_area = inter_w * inter_h

    area_a = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1)
    area_b = max(0.0, bx2 - bx1) * max(0.0, by2 - by1)
    union = area_a + area_b - inter_area

    return inter_area / union if union > 0 else 0.0