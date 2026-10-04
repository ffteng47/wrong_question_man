"""
API 路由 — tasks.py
GET /api/v1/tasks/{task_id}   查询任务状态与结果
"""
from fastapi import APIRouter, HTTPException

from app.models.schema import TaskInfo
from app.services import task_store

router = APIRouter()


@router.get("/tasks/{task_id}", response_model=TaskInfo)
async def get_task(task_id: str):
    task = task_store.get(task_id)
    if task is None:
        raise HTTPException(status_code=404, detail="任务不存在")
    return task
