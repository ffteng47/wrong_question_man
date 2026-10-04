"""
异步任务存储 — 单进程 asyncio 执行 + JSON 持久化（storage/tasks/）
无 Redis/Celery：本服务设计为 uvicorn 单 worker。
状态机：pending → processing → done | failed
"""
from __future__ import annotations
import asyncio
import json
import logging
import uuid
from datetime import datetime, timezone
from typing import Any, Awaitable, Callable, Coroutine

from app.config import settings
from app.models.schema import TaskInfo, TaskKind

logger = logging.getLogger(__name__)

_TASKS: dict[str, TaskInfo] = {}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _path(task_id: str):
    return settings.tasks_dir / f"{task_id}.json"


def _persist(task: TaskInfo) -> None:
    _path(task.task_id).write_text(
        task.model_dump_json(indent=2), encoding="utf-8"
    )


def create(kind: TaskKind) -> TaskInfo:
    task = TaskInfo(task_id=str(uuid.uuid4()), kind=kind)
    _TASKS[task.task_id] = task
    _persist(task)
    return task


def get(task_id: str) -> TaskInfo | None:
    if task_id in _TASKS:
        return _TASKS[task_id]
    p = _path(task_id)
    if p.exists():
        try:
            task = TaskInfo(**json.loads(p.read_text(encoding="utf-8")))
            _TASKS[task_id] = task
            return task
        except Exception as e:
            logger.warning(f"任务文件损坏: {p}: {e}")
    return None


def _set(task_id: str, **fields: Any) -> None:
    task = _TASKS.get(task_id)
    if task is None:
        return
    for k, v in fields.items():
        setattr(task, k, v)
    task.updated_at = _now()
    _persist(task)


def spawn(
    task_id: str,
    factory: Callable[[], Coroutine[Any, Any, dict]],
) -> asyncio.Task:
    """把协程挂到事件循环执行，并维护任务状态。factory 返回 result dict。"""

    async def _runner():
        _set(task_id, status="processing")
        try:
            result = await factory()
            _set(task_id, status="done", result=result)
        except Exception as e:
            logger.exception(f"任务失败: {task_id}")
            _set(task_id, status="failed", error=str(e)[:1000])

    return asyncio.create_task(_runner())


def sweep_stale() -> int:
    """启动清扫：重启前遗留的 pending/processing 任务一律标记 failed。"""
    n = 0
    for p in settings.tasks_dir.glob("*.json"):
        try:
            task = TaskInfo(**json.loads(p.read_text(encoding="utf-8")))
        except Exception:
            continue
        if task.status in ("pending", "processing"):
            task.status = "failed"
            task.error = "服务重启导致任务中断"
            task.updated_at = _now()
            _TASKS[task.task_id] = task
            _persist(task)
            n += 1
    if n:
        logger.info(f"清扫僵死任务 {n} 个")
    return n
