"""
Pydantic 数据模型 — 对应 wrong_answer_schema_v2.json
"""
from __future__ import annotations
from typing import Optional, Literal
from pydantic import BaseModel, Field
import uuid
from datetime import datetime, timezone


# ── MinerU 原始 content_block ─────────────────────────────────────────────────

class ContentBlock(BaseModel):
    id: str
    type: Literal["text", "formula", "table", "figure", "title", "image"]
    content: str = ""
    bbox: list[float] = Field(default_factory=list)   # [x1, y1, x2, y2] 原图像素
    latex: Optional[str] = None          # type=formula 时存在
    asset_path: Optional[str] = None     # type=figure 时存在
    score: Optional[float] = None        # MinerU 置信度


# ── 资源（裁切图片）────────────────────────────────────────────────────────────

class Asset(BaseModel):
    id: str                              # 如 "fig_1"
    type: str = "figure"
    src_path: str                        # 相对 storage_root，如 "assets/xxx/fig_1.png"
    bbox_in_original: list[float]        # [x1, y1, x2, y2]
    bbox_in_roi: Optional[list[float]] = None
    caption: str = ""
    markdown_ref: str = ""              # "![caption](assets/xxx/fig_1.png)"


# ── 错因分析 ──────────────────────────────────────────────────────────────────

class ErrorAnalysis(BaseModel):
    student_answer: str = ""
    error_category: Literal[
        "概念混淆", "计算失误", "审题不清", "知识缺漏", "方法选错", "粗心大意", "未知"
    ] = "未知"
    error_desc: str = ""
    prevention_tip: str = ""


# ── 知识点 ────────────────────────────────────────────────────────────────────

class KnowledgePoint(BaseModel):
    chapter: str
    point: str


# ── 用户选区（Flutter 传来的 ROI）────────────────────────────────────────────

class UserSelection(BaseModel):
    roi_bbox: list[float]                # [x1, y1, x2, y2] 相对原图像素
    roi_image_path: Optional[str] = None
    selection_mode: str = "free_draw"


class Source(BaseModel):
    image_path: str                      # originals/ 下的相对路径
    image_source: Literal["camera", "scanner"] = "camera"
    page_width_px: int = 0
    page_height_px: int = 0
    dpi_equivalent: int = 300
    user_selection: Optional[UserSelection] = None


# ── 核心记录 ──────────────────────────────────────────────────────────────────

class WrongAnswerRecord(BaseModel):
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    created_at: str = Field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )
    updated_at: str = Field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )

    source: Source

    type: str = "未知"                   # 应用题 / 选择题 / 填空题 …
    seq: Optional[int] = None           # 大题序号
    sub_seq: Optional[str] = None       # 小题编号 "(3)"

    problem: str = ""                   # Markdown，含 $LaTeX$ 和 ![](assets/…)
    answer: str = ""
    solution: str = ""

    assets: list[Asset] = Field(default_factory=list)

    subject: str = "未知"
    grade: str = "未知"
    chapters: list[str] = Field(default_factory=list)
    knowledge_points: list[str] = Field(default_factory=list)
    key_points: list[str] = Field(default_factory=list)

    real_score: float = 0
    difficulty: int = Field(default=3, ge=1, le=5)
    difficulty_desc: str = ""

    error_analysis: ErrorAnalysis = Field(default_factory=ErrorAnalysis)

    review_status: Literal["pending", "reviewing", "mastered"] = "pending"
    tags: list[str] = Field(default_factory=list)


# ── API 请求 / 响应模型 ───────────────────────────────────────────────────────

class UploadResponse(BaseModel):
    image_id: str
    width_px: int
    height_px: int
    preview_blocks: list[ContentBlock]   # 仅含 bbox+type，用于 Flutter 绘制覆盖层


class ExtractRequest(BaseModel):
    image_id: str
    roi_bbox: list[float]                # [x1, y1, x2, y2]
    image_source: Literal["camera", "scanner"] = "camera"
    enable_semantic: bool = True


class ExtractResponse(BaseModel):
    record: WrongAnswerRecord
    debug: Optional[dict] = None         # debug=True 时附带原始响应


class SaveRequest(BaseModel):
    record: WrongAnswerRecord            # 用户编辑后的完整记录


class SaveResponse(BaseModel):
    id: str
    saved_at: str


class HealthResponse(BaseModel):
    status: str
    mineru_ok: bool
    qwen_ok: bool
    storage_ok: bool
