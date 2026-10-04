"""
API 路由 — extract.py
POST /api/v1/extract → 创建 extract 任务，返回 {task_id}
结果通过 GET /api/v1/tasks/{task_id} 轮询（result 为 ExtractResponse）
"""
from fastapi import APIRouter, HTTPException

from app.config import settings
from app.models.schema import ExtractRequest, TaskAccepted
from app.services import task_store
from app.services.pipeline import run_extract

router = APIRouter()


@router.post("/extract", response_model=TaskAccepted)
async def extract_record(req: ExtractRequest):
    """
    传入 image_id + question_region（可选 answer_region），异步产出 WrongAnswerRecord。
    region.coord_space: "0_1000"（默认）| "pixel"；兼容旧版 roi_bbox（像素）。
    """
    try:
        question = req.resolved_question_region()
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))
    if len(question.bbox) != 4:
        raise HTTPException(status_code=422, detail="bbox 必须是 [x1, y1, x2, y2]")

    task = task_store.create("extract")
    task_store.spawn(task.task_id, lambda: _run(req, question))
    return TaskAccepted(task_id=task.task_id)


async def _run(req: ExtractRequest, question) -> dict:
    result = await run_extract(
        image_id=req.image_id,
        originals_dir=settings.originals_dir,
        question_region=question,
        answer_region=req.answer_region,
        image_source=req.image_source,
        enable_semantic=req.enable_semantic,
    )
    return result.model_dump()
