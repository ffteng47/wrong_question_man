"""
API 路由 — save.py
POST /api/v1/save        保存（新建或覆盖）
GET  /api/v1/records     列表（分页）
GET  /api/v1/records/{id} 单条
DELETE /api/v1/records/{id}
"""
from __future__ import annotations
from fastapi import APIRouter, HTTPException, Query
from pathlib import Path
import json
from datetime import datetime, timezone

from app.config import settings
from app.models.schema import SaveRequest, SaveResponse, WrongAnswerRecord

router = APIRouter()

# 简单文件存储（一条记录一个 JSON 文件），无需数据库依赖
# Flutter 端 sqflite 是主存储，服务端这里仅做备份/查询
_RECORDS_DIR = settings.storage_root / "records"
_RECORDS_DIR.mkdir(parents=True, exist_ok=True)


@router.post("/save", response_model=SaveResponse)
async def save_record(req: SaveRequest):
    """保存用户确认/编辑后的记录"""
    record = req.record
    record.updated_at = datetime.now(timezone.utc).isoformat()

    record_path = _RECORDS_DIR / f"{record.id}.json"
    record_path.write_text(
        record.model_dump_json(indent=2),
        encoding="utf-8",
    )

    return SaveResponse(id=record.id, saved_at=record.updated_at)


@router.get("/records", response_model=list[WrongAnswerRecord])
async def list_records(
    subject: str | None = Query(default=None),
    grade: str | None = Query(default=None),
    review_status: str | None = Query(default=None),
    limit: int = Query(default=20, le=100),
    offset: int = Query(default=0),
):
    """列出已保存的记录（支持简单过滤）"""
    files = sorted(_RECORDS_DIR.glob("*.json"), reverse=True)
    results: list[WrongAnswerRecord] = []

    for f in files:
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
            r = WrongAnswerRecord(**data)
        except Exception:
            continue

        if subject and r.subject != subject:
            continue
        if grade and r.grade != grade:
            continue
        if review_status and r.review_status != review_status:
            continue

        results.append(r)

    return results[offset: offset + limit]


@router.get("/records/{record_id}", response_model=WrongAnswerRecord)
async def get_record(record_id: str):
    record_path = _RECORDS_DIR / f"{record_id}.json"
    if not record_path.exists():
        raise HTTPException(status_code=404, detail="记录不存在")
    data = json.loads(record_path.read_text(encoding="utf-8"))
    return WrongAnswerRecord(**data)


@router.delete("/records/{record_id}")
async def delete_record(record_id: str):
    record_path = _RECORDS_DIR / f"{record_id}.json"
    if not record_path.exists():
        raise HTTPException(status_code=404, detail="记录不存在")
    record_path.unlink()
    return {"deleted": record_id}
