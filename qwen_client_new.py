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


# ── Qwen 输出的 JSON Schema（语义字段子集）────────────────────────────────────
SEMANTIC_SCHEMA = {
    "type": "object",
    "required": [
        "type", "seq", "sub_seq",
        "problem", "answer", "solution",
        "subject", "grade", "chapters",
        "knowledge_points", "key_points",
        "difficulty", "difficulty_desc",
        "error_analysis", "tags"
    ],
    "properties": {
        "type": {
            "type": "string",
            "enum": ["选择题", "多选题", "填空题", "计算题", "证明题", "应用题", "作图题", "综合题", "未知"]
        },
        "seq": {"type": ["integer", "null"]},
        "sub_seq": {"type": ["string", "null"]},
        "problem": {"type": "string", "description": "题干 Markdown，LaTeX 用 $...$ 包裹"},
        "answer": {"type": "string"},
        "solution": {"type": "string", "description": "解题过程 Markdown"},
        "subject": {
            "type": "string",
            "enum": ["语文", "数学", "英语", "物理", "化学", "生物", "历史", "地理", "政治", "未知"]
        },
        "grade": {
            "type": "string",
            "enum": ["初一", "初二", "初三", "高一", "高二", "高三", "未知"]
        },
        "chapters": {"type": "array", "items": {"type": "string"}},
        "knowledge_points": {"type": "array", "items": {"type": "string"}},
        "key_points": {
            "type": "array",
            "items": {"type": "string"},
            "description": "每条说明考察的能力，不超过 3 条"
        },
        "difficulty": {"type": "integer", "minimum": 1, "maximum": 5},
        "difficulty_desc": {"type": "string"},
        "error_analysis": {
            "type": "object",
            "properties": {
                "student_answer": {"type": "string"},
                "error_category": {
                    "type": "string",
                    "enum": ["概念混淆", "计算失误", "审题不清", "知识缺漏", "方法选错", "粗心大意", "未知"]
                },
                "error_desc": {"type": "string"},
                "prevention_tip": {"type": "string"}
            },
            "required": ["student_answer", "error_category", "error_desc", "prevention_tip"]
        },
        "tags": {"type": "array", "items": {"type": "string"}}
    },
    "additionalProperties": False
}

_SYSTEM_PROMPT = (
    "你是专业的中学题目分析助手。\n"
    "请从给定的 OCR 文本中分析题目，填充结构化信息。\n"
    "规则：\n"
    "1. 所有数学公式用 $...$ 包裹（行内），多行公式用 $$...$$\n"
    "2. problem/answer/solution 字段使用 Markdown 格式\n"
    "3. 若图片已用 [图片: xxx] 标记，在对应 Markdown 中保留占位\n"
    "4. 若 OCR 文本中有学生的错误解答（红笔批改等），填入 error_analysis.student_answer\n"
    "5. 必须返回合法 JSON，不得包含任何其他内容、解释或 Markdown 代码块\n"
    "6. JSON 必须严格符合以下 Schema，字段不能多也不能少\n"
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
