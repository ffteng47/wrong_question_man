"""
Qwen2.5-VL-7B-Instruct-AWQ 客户端（本地 transformers 推理）
- 直接加载 AWQ 模型进行本地推理
- 使用 prompt 约束 + 后处理提取 JSON，替代 vLLM guided_json
- 输入：OCR 文本；输出：WrongAnswerRecord 的语义字段
"""
from __future__ import annotations
import json
import logging
import re
import torch
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


# ── Qwen 输出的 JSON Schema（仅提取题目）────────────────────────────────────
SEMANTIC_SCHEMA = {
    "type": "object",
    "required": ["problem"],
    "properties": {
        "problem": {
            "type": "string",
            "description": "仅提取完整的题目原文（题干），保留 LaTeX 公式 $...$ 格式。自动过滤学生答题痕迹。"
        },
        "type": {"type": "string"},
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

_SYSTEM_PROMPT = (
    "你是中学题目提取助手。\n"
    "任务：从给定的 OCR 文本中，仅提取**完整的题目原文**（题干）。\n"
    "规则：\n"
    "1. 只返回题目本身，**不要**返回学生答案、解题过程、错因分析\n"
    "2. 如果 OCR 文本中包含学生答题痕迹（如红笔批改、手写解答），请自动过滤\n"
    "3. 数学公式保留 $...$ 格式（行内）或 $$...$$ 格式（块级）\n"
    "4. 题目中的图片占位符 [图片: xxx] 请保留\n"
    "5. 必须返回合法 JSON，不得包含任何其他内容、解释或 Markdown 代码块\n"
    "6. JSON 中 problem 字段必填，其他字段可空\n"
    "7. **请根据题目内容准确推断学科类型**（数学/语文/英语/物理/化学/生物/历史/地理/政治），"
    "并在 subject 字段中返回最匹配的学科名称\n"
)


def _extract_json(text: str) -> str:
    """
    从模型输出中提取 JSON 字符串。
    先尝试直接找 ```json ... ``` 代码块，再尝试找第一个 { 到最后一个 }。
    """
    # 1. 尝试提取 markdown json 代码块
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    if m:
        return m.group(1)

    # 2. 尝试找第一个 { 到最后一个 }
    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end != -1 and end > start:
        return text[start:end + 1]

    return text


async def analyze_semantic(ocr_text: str) -> dict:
    """
    调用 Qwen2.5-VL 进行语义分析。
    返回填充了语义字段的 dict（对应 SEMANTIC_SCHEMA）。
    """
    model, processor = _load_model()

    messages = [
        {"role": "system", "content": _SYSTEM_PROMPT + "\nSchema: " + json.dumps(SEMANTIC_SCHEMA, ensure_ascii=False)},
        {"role": "user", "content": f"题目文本：\n\n{ocr_text}"}
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
    # 去掉 prompt 部分，只保留 assistant 的回复
    raw_content = raw_content.split("assistant\n")[-1].strip()

    if settings.debug:
        logger.debug(f"[Qwen 原始输出]\n{raw_content[:500]}")

    json_str = _extract_json(raw_content)

    # 修复模型输出中 LaTeX 反斜杠未转义的问题（如 \mathsf, \frac 等）
    # 只修复 JSON 中非法的转义：前面不是 \ 且后面不是合法转义字符的单反斜杠
    json_str = re.sub(r'(?<!\\)\\(?!["\\\\/bfnrt])', r'\\\\', json_str)

    try:
        result = json.loads(json_str)
    except json.JSONDecodeError as e:
        logger.error(f"Qwen 输出 JSON 解析失败: {e}\n原始: {raw_content[:500]}")
        raise RuntimeError(f"Qwen JSON 解析失败: {e}") from e

    logger.info(f"Qwen 语义分析完成: subject={result.get('subject')}, type={result.get('type')}")
    return result


async def check_available() -> bool:
    """健康检查：模型是否已加载"""
    try:
        return _model is not None
    except Exception:
        return False
