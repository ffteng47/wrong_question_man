"""
Qwen2.5-VL-7B-Instruct-AWQ 客户端（本地 transformers 推理）
- 直接加载 AWQ 模型进行本地推理
- 使用 prompt 约束 + 后处理提取 JSON，替代 vLLM guided_json
- 输入：OCR 文本；输出：WrongAnswerRecord 的语义字段

修改记录：
  v1.1 - 新增 ocr_image()：直接用 Qwen Vision 识别图片中的题目文本，
          供 pipeline.py 的 Vision fallback 调用。
  v1.2 - 修复选择题选项丢失问题：
          原因：_SYSTEM_PROMPT 要求"过滤学生答案"，Qwen 误将 A/B/C/D 选项
          判定为学生作答内容而过滤掉，仅保留题干。
          修复：
            1. schema 新增 options 字段（字符串数组）
            2. prompt 明确说明选项是题目结构的一部分，不是学生答案
            3. 要求 Qwen 识别题型并填入 type 字段
            4. pipeline.py 侧：problem 字段追加 options 内容供前端显示
"""
from __future__ import annotations
from PIL import Image
import json
import logging
import re
import torch
from pathlib import Path
from transformers import Qwen2_5_VLForConditionalGeneration, AutoProcessor
from app.config import settings

logger = logging.getLogger(__name__)

# ── 模型单例 ────────────────────────────────────────────────────────────────
_model = None
_processor = None


def _load_model():
    global _model, _processor
    if _model is not None:
        return _model, _processor

    model_path = settings.qwen_model_id
    logger.info(f"Loading Qwen model from {model_path} ...")
    _model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
        model_path,
        dtype=torch.float16,
        device_map="auto",
        trust_remote_code=True,
    )
    _processor = AutoProcessor.from_pretrained(model_path, trust_remote_code=True)
    logger.info("Qwen model loaded successfully")
    return _model, _processor


# ── Schema ───────────────────────────────────────────────────────────────────

SEMANTIC_SCHEMA = {
    "type": "object",
    "required": ["problem", "type"],
    "properties": {
        "type": {
            "type": "string",
            "description": "题目类型，必须是以下之一：选择题、填空题、解答题、判断题、计算题、证明题、作图题、阅读理解、完形填空、其他"
        },
        "problem": {
            "type": "string",
            "description": "完整的题目题干（不含选项）。保留 LaTeX 公式 $...$ 格式，过滤学生手写答题痕迹。"
        },
        "options": {
            "type": "array",
            "items": {"type": "string"},
            "description": (
                "【仅选择题填写，其他题型留空数组】"
                "选择题的所有选项，每个元素是一个完整选项字符串，含选项标号，例如：'A. $a > 0$'。"
                "选项是题目的固有组成部分，不是学生答案，必须完整提取。"
            )
        },
        "seq": {"type": ["integer", "null"]},
        "sub_seq": {"type": ["string", "null"]},
        "answer": {"type": "string"},
        "solution": {"type": "string"},
        "subject": {"type": "string"},
        "grade": {"type": "string"},
        "chapters": {"type": "array", "items": {"type": "string"}},
        "knowledge_points": {"type": "array", "items": {"type": "string"}},
        "key_points": {"type": "array", "items": {"type": "string"}},
        "difficulty": {"type": "integer", "minimum": 1, "maximum": 5},
        "difficulty_desc": {"type": "string"},
        "error_analysis": {
            "type": "object",
            "properties": {
                "student_answer": {"type": "string"},
                "error_category": {"type": "string"},
                "error_desc": {"type": "string"},
                "prevention_tip": {"type": "string"}
            }
        },
        "tags": {"type": "array", "items": {"type": "string"}}
    }
}

# ── System Prompts ────────────────────────────────────────────────────────────

_SYSTEM_PROMPT = (
    "你是中学题目提取助手。\n"
    "任务：从给定的 OCR 文本中，提取完整的题目内容并输出结构化 JSON。\n\n"
    "【题型识别规则】\n"
    "- 含有 A. B. C. D. 或 A、B、C、D 选项的题目 → type='选择题'\n"
    "- 含有括号空白或横线需要填写的 → type='填空题'\n"
    "- 需要计算过程、证明、分析的 → type='解答题'/'计算题'/'证明题'\n"
    "- 其他情况 → type='其他'\n\n"
    "【选择题特别说明】\n"
    "选项 A/B/C/D 是题目本身的组成部分，不是学生的答案。\n"
    "必须将所有选项完整提取到 options 数组中，每个元素包含选项标号和内容。\n"
    "例如：[\"A. $a > 0$\", \"B. 对称轴为 $x = \\\\frac{3}{2}$\", \"C. $b = 2a$\", \"D. $4a+2b+c<0$\"]\n\n"
    "【过滤规则】\n"
    "- 过滤：学生用笔写的答案、解题过程（通常在题目旁边或下方，字迹潦草）\n"
    "- 过滤：红笔批改记号、对错符号\n"
    "- 保留：题目印刷体文字、题干、选项、图片占位符 [图片: xxx]\n"
    "- 保留：LaTeX 公式，用 $...$ 格式（行内）或 $$...$$ 格式（块级）\n\n"
    "【输出规则】\n"
    "1. 必须返回合法 JSON，不得包含任何其他内容、解释或 Markdown 代码块\n"
    "2. problem 和 type 字段必填\n"
    "3. 选择题的 options 必填且不能为空数组\n"
    "4. 非选择题的 options 填空数组 []\n"
    "5. 根据题目内容推断 subject（数学/语文/英语/物理/化学/生物/历史/地理/政治）\n"
    "6. 根据题目内容推断 subject 必填项不能为 None\n"
)

_OCR_SYSTEM_PROMPT = (
    "你是专业的试卷 OCR 助手。\n"
    "任务：完整、准确地识别图片中的题目文本。\n"
    "规则：\n"
    "1. 输出图片中所有可见的题目文字，包括题号、题干、选项（A/B/C/D）等\n"
    "2. 数学公式用 $...$ 格式（行内）或 $$...$$ 格式（块级）\n"
    "3. 保留原有的换行和结构，不要添加额外解释\n"
    "4. 如果图片中有学生手写的答案或批改痕迹，请忽略，只输出印刷体题目\n"
    "5. 只输出识别到的文本内容，不要说任何其他话\n"
)


# ── JSON 提取工具 ─────────────────────────────────────────────────────────────

def _extract_json(text: str) -> str:
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    if m:
        return m.group(1)
    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end != -1 and end > start:
        return text[start:end + 1]
    return text


# ── 语义分析 ─────────────────────────────────────────────────────────────────

async def analyze_semantic(ocr_text: str) -> dict:
    """
    调用 Qwen2.5-VL 进行语义分析。
    输入：MinerU OCR 提取的文本（或 Vision fallback 的识别文本）。
    返回填充了语义字段的 dict（含 options 字段）。
    """
    model, processor = _load_model()

    messages = [
        {
            "role": "system",
            "content": _SYSTEM_PROMPT + "\nSchema: " + json.dumps(SEMANTIC_SCHEMA, ensure_ascii=False)
        },
        {
            "role": "user",
            "content": f"题目文本：\n\n{ocr_text}"
        }
    ]

    text = processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    inputs = processor(text=[text], return_tensors="pt").to(model.device)

    if settings.debug:
        logger.debug(f"[Qwen 请求] ocr_text 长度={len(ocr_text)}")

    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=settings.qwen_max_tokens,
            temperature=settings.qwen_temperature,
            do_sample=True if settings.qwen_temperature > 0 else False,
        )

    raw_content = processor.batch_decode(outputs, skip_special_tokens=True)[0]
    raw_content = raw_content.split("assistant\n")[-1].strip()

    if settings.debug:
        logger.debug(f"[Qwen 原始输出]\n{raw_content[:500]}")

    json_str = _extract_json(raw_content)
    json_str = re.sub(r'(?<!\\)\\(?!["\\\\/bfnrt])', r'\\\\', json_str)

    try:
        result = json.loads(json_str)
    except json.JSONDecodeError as e:
        logger.error(f"Qwen 输出 JSON 解析失败: {e}\n原始: {raw_content[:500]}")
        raise RuntimeError(f"Qwen JSON 解析失败: {e}") from e

    # 保证 options 字段始终存在（兼容旧版模型输出可能没有此字段）
    if "options" not in result:
        result["options"] = []

    logger.info(
        f"Qwen 语义分析完成: subject={result.get('subject')}, "
        f"type={result.get('type')}, options数量={len(result.get('options', []))}"
    )
    return result


# ── Vision OCR（fallback）────────────────────────────────────────────────────

async def ocr_image(image_path: Path) -> str:
    """
    直接用 Qwen2.5-VL 视觉能力识别图片中的题目文本。

    供 pipeline.py 的 Vision fallback 调用：当 MinerU OCR 返回空文本时，
    将裁切好的 ROI 原图传入此函数，Qwen 直接看图识文字。

    返回识别到的文本（含 LaTeX 格式公式），失败时抛出异常。
    """
    model, processor = _load_model()

    # 加载图片为 PIL Image 对象
    image = Image.open(image_path)

    messages = [
        {"role": "system", "content": _OCR_SYSTEM_PROMPT},
        {
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "image": image,
                },
                {
                    "type": "text",
                    "text": "请识别图片中的题目文本，完整输出所有文字内容。",
                },
            ],
        },
    ]

    # 一步生成 inputs：提取图片 + 图像预处理 + tokenization + 返回可直接传给 model.generate() 的字典
    inputs = processor.apply_chat_template(
        messages,
        add_generation_prompt=True,
        tokenize=True,
        return_dict=True,
        return_tensors="pt",
    ).to(model.device)

    if settings.debug:
        logger.debug(f"[Qwen Vision OCR] 图片: {image_path.name}, 大小: {image_path.stat().st_size} bytes")

    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=1000,
            temperature=0,
            do_sample=False,
        )

    raw_content = processor.batch_decode(outputs, skip_special_tokens=True)[0]
    raw_content = raw_content.split("assistant\n")[-1].strip()

    if settings.debug:
        logger.debug(f"[Qwen Vision OCR 输出]\n{raw_content[:500]}")

    logger.info(f"Qwen Vision OCR 完成，识别文本长度={len(raw_content)}")
    return raw_content


async def check_available() -> bool:
    """健康检查：模型是否已加载"""
    try:
        return _model is not None
    except Exception:
        return False