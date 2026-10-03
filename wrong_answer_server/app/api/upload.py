"""
API 路由 — upload.py
POST /api/v1/upload
"""
import logging

from fastapi import APIRouter, UploadFile, File, Form
import aiofiles
import uuid
from pathlib import Path
from PIL import Image, ImageOps

from app.config import settings
from app.models.schema import UploadResponse
from app.services.pipeline import run_upload

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/upload", response_model=UploadResponse)
async def upload_image(
    image: UploadFile = File(..., description="试卷图片"),
    image_source: str = Form(default="camera", description="camera | scanner"),
):
    """
    上传图片，返回全页 content_blocks 预览。
    Flutter 用预览 blocks 的 bbox 在图片上绘制分块覆盖层，引导用户框选 ROI。
    """
    # 保存原图
    image_id = str(uuid.uuid4())
    suffix = Path(image.filename or "img.jpg").suffix.lower() or ".jpg"
    original_path = settings.originals_dir / f"{image_id}{suffix}"

    async with aiofiles.open(original_path, "wb") as f:
        content = await image.read()
        await f.write(content)

    # ── EXIF 规范化：将旋转"烧录"到像素，消除前后端坐标系不一致 ──────────
    try:
        with Image.open(original_path) as img:
            img = ImageOps.exif_transpose(img)   # 应用 EXIF Orientation，移除标签
            # JPEG 不支持 RGBA/P 模式，按需转换；PNG 保留原模式（含透明通道）
            if suffix in (".jpg", ".jpeg") and img.mode not in ("RGB", "L"):
                img = img.convert("RGB")
            save_kwargs = {"quality": 95, "subsampling": 0} if suffix in (".jpg", ".jpeg") else {}
            img.save(original_path, **save_kwargs)
        logger.info(f"EXIF 规范化完成: {original_path.name}")
    except Exception as e:
        # 规范化失败不中断上传，记录警告即可（正立图片走到这里是无害的）
        logger.warning(f"EXIF 规范化失败（跳过）: {e}")
    # ────────────────────────────────────────────────────────────────────────

    result = await run_upload(original_path, image_source=image_source)
    # run_upload 内部会把 stem 设为 UUID，这里覆盖确保一致
    result.image_id = image_id
    return result
