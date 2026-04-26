"""
资源提取器 — 用 Pillow 按 bbox 从原图裁切 figure block
并生成 Markdown 引用路径，注入到 problem/solution 文本中
"""
from __future__ import annotations
from pathlib import Path
from PIL import Image
import logging

from app.config import settings
from app.models.schema import ContentBlock, Asset

logger = logging.getLogger(__name__)


def extract_assets(
    original_path: Path,
    figure_blocks: list[ContentBlock],
    record_id: str,
) -> list[Asset]:
    """
    从原图裁切所有 type=figure 的 block，保存到 assets/{record_id}/ 目录。
    返回 Asset 列表（含 markdown_ref）。
    """
    assets: list[Asset] = []
    if not figure_blocks:
        return assets

    img = Image.open(original_path)
    asset_dir = settings.assets_dir / record_id
    asset_dir.mkdir(parents=True, exist_ok=True)

    for i, blk in enumerate(figure_blocks):
        if not blk.bbox or len(blk.bbox) < 4:
            logger.warning(f"figure block {blk.id} 没有有效 bbox，跳过")
            continue

        fig_id = f"fig_{i + 1}"
        dst_name = f"{fig_id}.png"
        dst_path = asset_dir / dst_name

        x1, y1, x2, y2 = (int(v) for v in blk.bbox[:4])
        cropped = img.crop((x1, y1, x2, y2))
        cropped.save(str(dst_path), "PNG")

        # 相对路径：Flutter 通过 /static/ 路由访问
        rel_path = f"assets/{record_id}/{dst_name}"
        caption = blk.content or f"图{i + 1}"
        markdown_ref = f"![{caption}]({rel_path})"

        asset = Asset(
            id=fig_id,
            src_path=rel_path,
            bbox_in_original=list(blk.bbox[:4]),
            caption=caption,
            markdown_ref=markdown_ref,
        )
        assets.append(asset)
        logger.debug(f"裁切 figure: {dst_path}, bbox={blk.bbox[:4]}")

    logger.info(f"提取 {len(assets)} 个 figure assets → assets/{record_id}/")
    return assets


def inject_assets_into_markdown(text: str, assets: list[Asset]) -> str:
    """
    将 Qwen 输出中的 [图片: xxx] 占位符替换为真实的 Markdown 图片引用。
    若没有占位符但有 assets，则追加到文本末尾。
    """
    if not assets:
        return text

    result = text
    for i, asset in enumerate(assets):
        # 尝试替换各种可能的占位格式
        placeholders = [
            f"[图片: {asset.id}]",
            f"[图片:assets/{asset.id}]",
            f"[图片]",
            f"[figure_{i+1}]",
        ]
        replaced = False
        for ph in placeholders:
            if ph in result:
                result = result.replace(ph, asset.markdown_ref, 1)
                replaced = True
                break

        if not replaced and i == 0:
            # 没有占位符时，将图片追加到题干末尾
            result = result + f"\n\n{asset.markdown_ref}"

    return result
