"""
FastAPI 入口 -- 错题系统中间层
端口: 9000
"""
from __future__ import annotations
import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from app.config import settings
from app.models.schema import HealthResponse
from app.api import upload, extract, save, tasks

# -- 日志 -------------------------------------------------------------------
logging.basicConfig(
    level=logging.DEBUG if settings.debug else logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s -- %(message)s",
)
logger = logging.getLogger(__name__)


# -- 启动/关闭事件 ------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    from app.services import task_store
    task_store.sweep_stale()
    logger.info("=" * 60)
    logger.info("Wrong Answer Server started")
    logger.info(f"  MinerU  : {settings.mineru_base_url}")
    logger.info(f"  Qwen    : {settings.qwen_base_url} ({settings.qwen_model_name})")
    logger.info(f"  Storage : {settings.storage_root}")
    logger.info(f"  Debug   : {settings.debug}")
    logger.info("=" * 60)
    yield
    logger.info("Server shutdown")


# -- 应用实例 -----------------------------------------------------------------
app = FastAPI(
    title="Wrong Answer API",
    version="1.0.0",
    description="MinerU + Qwen2.5-VL pipeline",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.mount(
    "/static",
    StaticFiles(directory=str(settings.storage_root)),
    name="static",
)

# -- 路由注册 -----------------------------------------------------------------
app.include_router(upload.router,  prefix="/api/v1", tags=["upload"])
app.include_router(extract.router, prefix="/api/v1", tags=["extract"])
app.include_router(save.router,    prefix="/api/v1", tags=["save"])
app.include_router(tasks.router,   prefix="/api/v1", tags=["tasks"])


# -- 健康检查 -----------------------------------------------------------------
@app.get("/health", response_model=HealthResponse, tags=["system"])
async def health():
    from app.core import mineru_client, qwen_client

    mineru_ok = await mineru_client.check_healthy()
    qwen_ok = await qwen_client.check_available()
    storage_ok = settings.storage_root.exists()

    status = "ok" if (mineru_ok and qwen_ok and storage_ok) else "degraded"
    return HealthResponse(
        status=status,
        mineru_ok=mineru_ok,
        qwen_ok=qwen_ok,
        storage_ok=storage_ok,
    )


@app.get("/", tags=["system"])
async def root():
    return {"message": "Wrong Answer API v1.0", "docs": "/docs"}
