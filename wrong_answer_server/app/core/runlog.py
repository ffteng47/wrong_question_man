"""
RecognitionRun 证据链 — 每次识别流程落一份 JSON 到 storage/runs/{record_id}/
记录各阶段的 provider/model/原始输出/清洗后输出，便于回溯 badcase。
"""
from __future__ import annotations
import json
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from app.config import settings


class RunLog:
    def __init__(self, record_id: str):
        self.run_id = str(uuid.uuid4())
        self.record_id = record_id
        self.created_at = datetime.now(timezone.utc).isoformat()
        self.stages: list[dict] = []
        self._t0 = time.perf_counter()

    def stage(
        self,
        name: str,
        provider: str,
        model: str | None,
        raw_output,
        corrected_output,
        extra: dict | None = None,
    ) -> None:
        entry = {
            "stage": name,
            "provider": provider,
            "model": model,
            "elapsed_ms": int((time.perf_counter() - self._t0) * 1000),
            "raw_output": raw_output,
            "corrected_output": corrected_output,
        }
        if extra:
            entry.update(extra)
        self.stages.append(entry)

    def flush(self) -> Path | None:
        try:
            d = settings.runs_dir / self.record_id
            d.mkdir(parents=True, exist_ok=True)
            path = d / f"{self.run_id}.json"
            path.write_text(json.dumps({
                "run_id": self.run_id,
                "record_id": self.record_id,
                "created_at": self.created_at,
                "stages": self.stages,
            }, ensure_ascii=False, indent=2), encoding="utf-8")
            return path
        except Exception:
            # 证据链落盘失败不影响主流程
            import logging
            logging.getLogger(__name__).exception("RunLog 落盘失败")
            return None
