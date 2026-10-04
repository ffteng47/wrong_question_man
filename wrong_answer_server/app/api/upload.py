"""
API 路由 — upload.py
POST /api/v1/upload → 创建 parse 任务，返回 {image_id, task_id}
结果通过 GET /api/v1/tasks/{task_id} 轮询（result 为 UploadResponse）
"""
import logging

from fastapi import APIRouter, UploadFile, File, Form
import aiofiles
import uuid
from pathlib import Path
from PIL import Image, ImageOps

from app.config import settings
from app.models.schema import TaskAccepted
from app.services import task_store
from app.services.pipeline import run_upload

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/upload", response_model=TaskAccepted)
async def upload_image(
    image: UploadFile = File(..., description="试卷图片"),
    image_source: str = Form(default="camera", description="camera | scanner"),
):
    """
    保存图片并创建全页解析任务。
    Flutter 轮询任务拿到 preview_blocks（bbox 0~1000）后绘制分块覆盖层。
    """
    image_id = str(uuid.uuid4())
    suffix = Path(image.filename or "img.jpg").suffix.lower() or ".jpg"
    original_path = settings.originals_dir / f"{image_id}{suffix}"

    async with aiofiles.open(original_path, "wb") as f:
        content = await image.read()
        await f.write(content)

    # ── EXIF 规范化：将旋转"烧录"到像素，消除前后端坐标系不一致 ──────────
    try:
        with Image.open(original_path) as img:
            img = ImageOps.exif_transpose(img)
            if suffix in (".jpg", ".jpeg") and img.mode not in ("RGB", "L"):
                img = img.convert("RGB")
            save_kwargs = {"quality": 95, "subsampling": 0} if suffix in (".jpg", ".jpeg") else {}
            img.save(original_path, **save_kwargs)
    except Exception as e:
        # 规范化失败不中断上传（正立图片走到这里是无害的）
        logger.warning(f"EXIF 规范化失败（跳过）: {e}")

    task = task_store.create("parse")
    task_store.spawn(
        task.task_id,
        lambda: _parse(original_path, image_id, image_source),
    )
    return TaskAccepted(task_id=task.task_id, image_id=image_id)


async def _parse(original_path: Path, image_id: str, image_source: str) -> dict:
    result = await run_upload(original_path, image_source=image_source)
    result.image_id = image_id  # stem 可能与 image_id 后缀不一致，强制覆盖
    return result.model_dump()
