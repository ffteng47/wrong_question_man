"""
全局配置 — 修改这里适配本机环境
"""
from pathlib import Path
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # ── 服务端口 ──────────────────────────────────────────
    api_port: int = 9000

    # ── 上游服务地址 ─────────────────────────────────────
    mineru_base_url: str = "http://127.0.0.1:8000"
    qwen_base_url: str = "http://127.0.0.1:8001"        # vLLM OpenAI 兼容端口
    qwen_model_id: str = "/home/tff/software/models/Qwen2.5-VL-7B-Instruct-AWQ"

    # ── 存储路径 ─────────────────────────────────────────
    storage_root: Path = Path(__file__).parent.parent / "storage"

    @property
    def originals_dir(self) -> Path:
        return self.storage_root / "originals"

    @property
    def rois_dir(self) -> Path:
        return self.storage_root / "rois"

    @property
    def assets_dir(self) -> Path:
        return self.storage_root / "assets"

    # ── 推理参数 ─────────────────────────────────────────
    # vLLM guided_json 约束解码，保证 100% 合法 JSON
    qwen_max_tokens: int = 2048
    qwen_temperature: float = 0.1        # 结构化任务用低温
    qwen_thinking_mode: bool = False      # Qwen3 thinking=off；Qwen2.5 无此参数

    # MinerU 置信度阈值：低于此值时强制触发语义分析
    mineru_confidence_threshold: float = 0.85

    # ROI block 筛选 IoU 阈值
    roi_iou_threshold: float = 0.5

    # ── 调试 ─────────────────────────────────────────────
    debug: bool = True                   # True 时打印原始 MinerU / Qwen 响应

    class Config:
        env_file = ".env"                # 可在 .env 里覆盖任意字段
        env_file_encoding = "utf-8"


settings = Settings()

# 启动时确保目录存在
for _d in (settings.originals_dir, settings.rois_dir, settings.assets_dir):
    _d.mkdir(parents=True, exist_ok=True)
