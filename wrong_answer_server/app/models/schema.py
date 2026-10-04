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


# ── 用户选区（Flutter 传来的框选区域）───────────────────────────────────────

class Region(BaseModel):
    bbox: list[float]                    # [x1, y1, x2, y2]
    coord_space: Literal["pixel", "0_1000"] = "0_1000"
    image_path: Optional[str] = None     # 服务端按此区域裁切后的相对路径
    text: str = ""                       # 该区域的识别文本（题干/手写作答）
    confidence: Optional[float] = None   # 保留字段，当前无可靠置信度


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
    question_region: Optional[Region] = None      # 题区
    answer_region: Optional[Region] = None        # 手写答案区（可选）
    # 旧版兼容：像素坐标 ROI
    roi_bbox: Optional[list[float]] = None
    image_source: Literal["camera", "scanner"] = "camera"
    enable_semantic: bool = True

    def resolved_question_region(self) -> Region:
        if self.question_region is not None:
            return self.question_region
        if self.roi_bbox is not None:
            return Region(bbox=self.roi_bbox, coord_space="pixel")
        raise ValueError("缺少 question_region / roi_bbox")


class ExtractResponse(BaseModel):
    record: WrongAnswerRecord
    debug: Optional[dict] = None         # debug=True 时附带原始响应


# ── 异步任务 ─────────────────────────────────────────────────────────────────

TaskKind = Literal["parse", "extract"]
TaskStatus = Literal["pending", "processing", "done", "failed"]


class TaskInfo(BaseModel):
    task_id: str
    kind: TaskKind
    status: TaskStatus = "pending"
    created_at: str = Field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )
    updated_at: str = Field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )
    result: Optional[dict] = None        # done 时为 UploadResponse / ExtractResponse 的 dict
    error: Optional[str] = None          # failed 时的错误信息


class TaskAccepted(BaseModel):
    task_id: str
    image_id: Optional[str] = None       # upload 时返回，供后续 extract 使用


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
