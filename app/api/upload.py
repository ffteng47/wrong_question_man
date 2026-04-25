"""
API 路由 — upload.py
POST /api/v1/upload
"""
from fastapi import APIRouter, UploadFile, File, Form
import aiofiles
import uuid
from pathlib import Path

from app.config import settings
from app.models.schema import UploadResponse
from app.services.pipeline import run_upload

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
    suffix = Path(image.filename or "img.jpg").suffix or ".jpg"
    original_path = settings.originals_dir / f"{image_id}{suffix}"

    async with aiofiles.open(original_path, "wb") as f:
        content = await image.read()
        await f.write(content)

    result = await run_upload(original_path, image_source=image_source)
    # run_upload 内部会把 stem 设为 UUID，这里覆盖确保一致
    result.image_id = image_id
    return result
