"""
MinerU 4.0 doclib API 客户端
工作流：POST /v1/uploads → PUT upload_url → POST /v1/uploads/{id}/complete
        → POST /v1/parse/jobs → 轮询 GET /v1/parse/jobs/{job_id}
        → GET /v1/files/{file_id}/content (middle_json, docvortex.middle v2.0)
bbox 为 0~1 归一化坐标，×1000 后与本系统 0~1000 约定一致。
"""
from __future__ import annotations
import asyncio
import hashlib
import httpx
import json
import logging
import mimetypes
import time
from pathlib import Path

from app.config import settings
from app.models.schema import ContentBlock

logger = logging.getLogger(__name__)

_TIMEOUT = httpx.Timeout(60.0, connect=10.0)

_TERMINAL = ("completed", "partial", "failed", "canceled")


def _map_mineru_type(mineru_type: str) -> str:
    """docvortex block type → ContentBlock type"""
    mapping = {
        "text": "text",
        "title": "title",
        "image": "figure",
        "figure": "figure",
        "table": "table",
        "equation": "formula",
        "formula": "formula",
    }
    return mapping.get(mineru_type, "text")


async def parse_image(image_path: Path) -> tuple[list[ContentBlock], float]:
    """
    调用 MinerU 4.0 解析单张图片，返回 (content_blocks, min_confidence)。
    blocks 的 bbox 已映射到 0~1000 坐标系。
    middle_json 不含置信度信息，min_confidence 恒为 1.0。
    """
    t0 = time.perf_counter()
    data = image_path.read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    mime = mimetypes.guess_type(image_path.name)[0] or "application/octet-stream"

    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        # 1. 申请上传
        up = (await client.post(
            f"{settings.mineru_base_url}/v1/uploads",
            json={"filename": image_path.name, "bytes": len(data),
                  "mime_type": mime, "purpose": "parse"},
        )).raise_for_status().json()

        # 2. 上传内容
        put_resp = await client.put(up["upload_url"], content=data,
                                    headers={"Content-Type": "application/octet-stream"})
        put_resp.raise_for_status()

        # 3. 完成上传 → file_id
        done = (await client.post(
            f"{settings.mineru_base_url}/v1/uploads/{up['id']}/complete",
            json={"sha256sum": sha},
        )).raise_for_status().json()
        file_id = done["file"]["id"]

        # 4. 创建解析任务
        job = (await client.post(
            f"{settings.mineru_base_url}/v1/parse/jobs",
            json={
                "files": [{"source": {"type": "file_id", "file_id": file_id}}],
                "output_formats": ["middle_json"],
                "ocr_mode": settings.mineru_ocr_mode,
            },
        )).raise_for_status().json()
        job_id = job["job_id"]

        # 5. 轮询任务状态
        deadline = time.monotonic() + settings.mineru_job_timeout
        while True:
            job = (await client.get(
                f"{settings.mineru_base_url}/v1/parse/jobs/{job_id}"
            )).raise_for_status().json()
            if job["status"] in _TERMINAL:
                break
            if time.monotonic() > deadline:
                raise TimeoutError(f"MinerU 解析超时: job={job_id} status={job['status']}")
            await asyncio.sleep(settings.mineru_poll_interval)

        if job["status"] in ("failed", "canceled"):
            raise RuntimeError(f"MinerU 解析失败: {json.dumps(job, ensure_ascii=False)[:500]}")

        # 6. 拉取 middle_json
        middle_fid = job["files"][0]["output_files"]["middle_json"]["file_id"]
        middle = (await client.get(
            f"{settings.mineru_base_url}/v1/files/{middle_fid}/content"
        )).raise_for_status().json()

    blocks = _middle_to_blocks(middle)
    elapsed = int((time.perf_counter() - t0) * 1000)
    logger.info(f"MinerU 解析完成: {len(blocks)} blocks, {elapsed}ms, status={job['status']}")
    return blocks, 1.0


def _flatten_content(content) -> str:
    """block.content 可能是字符串，也可能是 span 列表（如 [{'type':'text','content':…}]）"""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for span in content:
            if isinstance(span, dict):
                v = span.get("content") or span.get("text") or span.get("html") or ""
                parts.append(_flatten_content(v))
            elif isinstance(span, str):
                parts.append(span)
        return "".join(parts)
    return ""


def _middle_to_blocks(middle: dict) -> list[ContentBlock]:
    """docvortex.middle v2.0 → ContentBlock 列表（bbox 0~1 → 0~1000）"""
    blocks: list[ContentBlock] = []
    i = 0
    for page in middle.get("pages", []):
        for blk in page.get("blocks", []):
            raw_bbox = blk.get("bbox") or []
            bbox = [float(v) * 1000 for v in raw_bbox[:4]] if len(raw_bbox) >= 4 else []
            blk_type = _map_mineru_type(blk.get("type", "text"))
            content = _flatten_content(blk.get("content"))
            blocks.append(ContentBlock(
                id=f"blk_{i}",
                type=blk_type,
                content=content,
                bbox=bbox,
                latex=content if blk_type == "formula" else None,
                asset_path=None,
                score=None,
            ))
            i += 1
    return blocks


async def check_healthy() -> bool:
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(5.0)) as client:
            r = await client.get(f"{settings.mineru_base_url}/v1/health")
            return r.status_code == 200
    except Exception:
        return False


def filter_blocks_by_roi(
    blocks: list[ContentBlock],
    roi_bbox: list[float],
    iou_threshold: float | None = None,
) -> list[ContentBlock]:
    """
    筛选与 ROI 重叠的 blocks（IoB > threshold）。
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

        iob = _iob(blk.bbox, roi)
        if iob >= threshold:
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
    计算 Intersection over Block（交集 / block 自身面积），bbox 格式 [x1,y1,x2,y2]。

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

    area_a = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1)

    return inter_area / area_a if area_a > 0 else 0.0
