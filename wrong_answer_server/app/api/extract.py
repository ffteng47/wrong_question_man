"""
API 路由 — extract.py
POST /api/v1/extract
"""
from fastapi import APIRouter, HTTPException
from app.config import settings
from app.models.schema import ExtractRequest, ExtractResponse
from app.services.pipeline import run_extract

router = APIRouter()


@router.post("/extract", response_model=ExtractResponse)
async def extract_record(req: ExtractRequest):
    """
    传入 image_id + roi_bbox，返回完整 WrongAnswerRecord。
    roi_bbox 格式：[x1, y1, x2, y2]，相对原图像素坐标。
    """
    if len(req.roi_bbox) != 4:
        raise HTTPException(status_code=422, detail="roi_bbox 必须是 [x1, y1, x2, y2]")

    try:
        result = await run_extract(
            image_id=req.image_id,
            originals_dir=settings.originals_dir,
            roi_bbox=req.roi_bbox,
            image_source=req.image_source,
            enable_semantic=req.enable_semantic,
        )
    except FileNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=500, detail=str(e))

    return result
