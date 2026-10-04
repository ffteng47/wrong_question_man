"""
Qwen2.5-VL 客户端 — 经 vLLM OpenAI 兼容接口（settings.qwen_base_url）
- analyze_semantic : OCR 文本 → 结构化语义字段（response_format=json_object）
- ocr_image        : 直接看图识别题目文本（Vision fallback）
- detect_figures_in_image : visual grounding 检测插图

对外签名与旧 transformers 版保持一致。
"""
from __future__ import annotations
import base64
import httpx
import json
import logging
import mimetypes
import re
from pathlib import Path

from app.config import settings

logger = logging.getLogger(__name__)

_TIMEOUT = httpx.Timeout(180.0, connect=10.0)


# ── Schema ───────────────────────────────────────────────────────────────────

SEMANTIC_SCHEMA = {
    "type": "object",
    "required": ["problem", "type", "subject"],
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
        "subject": {"type": "string"},
        "answer": {
            "type": "string",
            "description": "参考答案/标准答案。仅当 OCR 文本中存在印刷体标准答案时提取；学生手写作答不算。没有则空字符串。"
        },
        "solution": {
            "type": "string",
            "description": "参考解析/解题过程。仅当 OCR 文本中存在印刷体解析时提取；学生手写作答不算。没有则空字符串。"
        },
        "student_answer": {
            "type": "string",
            "description": (
                "若 OCR 文本中混有学生的手写作答/解题过程（如「解：设…」「答：…」及算式推导），"
                "将其完整原样提取到这里；没有则为空字符串。"
            )
        },
        "tags": {"type": "array", "items": {"type": "string"}}
    }
}

# ── System Prompts ────────────────────────────────────────────────────────────

_SYSTEM_PROMPT = (
    "你是中学题目提取助手。\n"
    "任务：从给定的 OCR 文本中，提取完整的题目内容并输出结构化 JSON。必须过滤手写痕迹。\n\n"
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
    "- 学生用笔写的答案、解题过程（通常在题目旁边或下方，字迹潦草）：不要混入 problem，而是完整原样提取到 student_answer 字段\n"
    "- 过滤：红笔批改记号、对错符号\n"
    "- 保留：题目印刷体文字、题干、选项、图片占位符 [图片: xxx]\n"
    "- 保留：LaTeX 公式，用 $...$ 格式（行内）或 $$...$$ 格式（块级）\n\n"
    "【答案与解析字段】\n"
    "- answer：仅提取印刷体的标准答案/参考答案；学生手写作答不算，放 student_answer\n"
    "- solution：仅提取印刷体的参考解析/解题过程；学生手写的解题过程不算，放 student_answer\n"
    "- student_answer：抽取时若文本里混有学生手写作答/解题过程，完整原样提取到这里，并从 problem 中剔除\n"
    "- 以上三个字段若无内容则填空字符串 \\\"\\\"\n\n"
    "【输出规则】\n"
    "1. 必须返回合法 JSON，不得包含任何其他内容、解释或 Markdown 代码块\n"
    "2. problem、type、subject 字段必填，且不能为 null\n"
    "3. 选择题的 options 必填且不能为空数组\n"
    "4. 非选择题的 options 填空数组 []\n"
    "5. subject 必须是：数学/语文/英语/物理/化学/生物/历史/地理/政治 之一\n"
    "6. answer/solution/student_answer 无内容时填空字符串，不要省略字段，不能为 null\n"
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

_FIGURE_DETECTION_PROMPT = (
    "检测图片中的所有插图、示意图、几何图形或图表。"
    "忽略纯文字区域，只检测包含图形、线条、形状的非文字视觉元素。"
    "对每个检测到的图形，输出其边界框坐标和简要类型标签。"
    "输出格式：JSON数组，每个元素为 "
    '{"bbox_2d": [x1, y1, x2, y2], "label": "图形类型"}。'
    "如果没有检测到任何图形，返回空数组 []。"
)


# ── vLLM 请求封装 ─────────────────────────────────────────────────────────────

def _image_data_url(image_path: Path) -> str:
    mime = mimetypes.guess_type(image_path.name)[0] or "image/jpeg"
    b64 = base64.b64encode(image_path.read_bytes()).decode()
    return f"data:{mime};base64,{b64}"


async def _chat(
    messages: list[dict],
    *,
    max_tokens: int | None = None,
    temperature: float | None = None,
    json_mode: bool = False,
) -> str:
    payload: dict = {
        "model": settings.qwen_model_name,
        "messages": messages,
        "max_tokens": max_tokens or settings.qwen_max_tokens,
        "temperature": settings.qwen_temperature if temperature is None else temperature,
    }
    if json_mode:
        payload["response_format"] = {"type": "json_object"}

    async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
        resp = await client.post(
            f"{settings.qwen_base_url}/v1/chat/completions", json=payload
        )
        resp.raise_for_status()
        data = resp.json()

    content = data["choices"][0]["message"]["content"] or ""
    if settings.debug:
        logger.debug(f"[Qwen 原始输出]\n{content[:500]}")
    return content


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

async def analyze_semantic(ocr_text: str, student_answer: str | None = None) -> dict:
    """
    调用 Qwen2.5-VL 进行语义分析。
    输入：MinerU OCR 提取的文本（或 Vision fallback 的识别文本），
          可选学生手写作答文本（answer_region OCR 结果，仅用于辅助过滤，不计入题干）。
    返回填充了语义字段的 dict（含 options 字段）。
    """
    user_content = f"题目文本：\n\n{ocr_text}"
    if student_answer:
        user_content += f"\n\n学生作答（非题目内容，需从题干中过滤）：\n{student_answer}"

    messages = [
        {
            "role": "system",
            "content": _SYSTEM_PROMPT + "\n输出必须符合以下 JSON Schema: "
                       + json.dumps(SEMANTIC_SCHEMA, ensure_ascii=False)
        },
        {"role": "user", "content": user_content},
    ]

    raw = await _chat(messages, json_mode=True)

    json_str = _extract_json(raw)
    json_str = re.sub(r'(?<!\\)\\(?!["\\/bfnrtu])', r'\\\\', json_str)

    try:
        result = json.loads(json_str)
    except json.JSONDecodeError as e:
        logger.error(f"Qwen 输出 JSON 解析失败: {e}\n原始: {raw[:500]}")
        raise RuntimeError(f"Qwen JSON 解析失败: {e}") from e

    # 保证 options 字段始终存在
    if "options" not in result:
        result["options"] = []

    # ── LaTeX 公式清洗：去除过度空格化 ────────────────────────────────────────
    for key in ("problem", "solution", "answer"):
        if result.get(key):
            result[key] = _clean_latex_formulas(result[key])
    if result.get("options"):
        result["options"] = [_clean_latex_formulas(opt) for opt in result["options"]]

    logger.info(
        f"Qwen 语义分析完成: subject={result.get('subject')}, "
        f"type={result.get('type')}, options数量={len(result.get('options', []))}"
    )
    return result


# ── Vision OCR（fallback）────────────────────────────────────────────────────

async def ocr_image(image_path: Path) -> str:
    """
    直接用 Qwen2.5-VL 视觉能力识别图片中的题目文本。
    供 pipeline.py 的 Vision fallback 与 answer_region 手写作答识别调用。
    """
    messages = [
        {"role": "system", "content": _OCR_SYSTEM_PROMPT},
        {
            "role": "user",
            "content": [
                {"type": "image_url", "image_url": {"url": _image_data_url(image_path)}},
                {"type": "text", "text": "请识别图片中的题目文本，完整输出所有文字内容。"},
            ],
        },
    ]
    raw = await _chat(messages, max_tokens=1000, temperature=0)
    logger.info(f"Qwen Vision OCR 完成，识别文本长度={len(raw)}")
    return raw


# ── Visual Grounding：插图/示意图检测 ─────────────────────────────────────────

async def detect_figures_in_image(image_path: Path) -> list[dict]:
    """
    使用 Qwen2.5-VL visual grounding 检测图片中的插图/示意图。

    返回: [{"bbox_2d": [x1, y1, x2, y2], "label": "..."}, ...]
    坐标为输入图片内的像素坐标（与旧版约定一致）。
    """
    messages = [
        {"role": "system", "content": "你是专业的文档图像分析助手，擅长检测插图和示意图。"},
        {
            "role": "user",
            "content": [
                {"type": "image_url", "image_url": {"url": _image_data_url(image_path)}},
                {"type": "text", "text": _FIGURE_DETECTION_PROMPT},
            ],
        },
    ]
    raw = await _chat(messages, max_tokens=500, temperature=0, json_mode=True)

    json_str = _extract_json(raw)
    try:
        result = json.loads(json_str)
    except json.JSONDecodeError:
        logger.warning(f"图形检测 JSON 解析失败: {raw[:200]}")
        return []

    if isinstance(result, list):
        logger.info(f"Qwen 图形检测完成，检测到 {len(result)} 个图形")
        return result
    if isinstance(result, dict) and "bbox_2d" in result:
        return [result]
    return []


async def check_available() -> bool:
    """健康检查：vLLM 服务是否可达且模型已加载"""
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(5.0)) as client:
            r = await client.get(f"{settings.qwen_base_url}/v1/models")
            if r.status_code != 200:
                return False
            return any(
                m.get("id") == settings.qwen_model_name for m in r.json().get("data", [])
            )
    except Exception:
        return False


# ── LaTeX 清洗 ────────────────────────────────────────────────────────────────

def _clean_latex_math(inner: str) -> str:
    """
    清洗单个数学块内部的 LaTeX 公式，去除过度空格化。
    """
    prev = None
    while prev != inner:
        prev = inner

        # 1. 命令与参数之间的空格：\frac { → \frac{
        inner = re.sub(r'\\([a-zA-Z]+)\s+\{', r'\\\1{', inner)

        # 2. 花括号内部的多余空格：{ 1 } → {1}
        inner = re.sub(r'\{\s+([^}{]*?)\s+\}', r'{\1}', inner)

        # 3. 运算符与花括号之间的空格：x ^ { → x^{, x _ { → x_{
        inner = re.sub(r'(\w)\s*\^\s*\{', r'\1^{', inner)
        inner = re.sub(r'(\w)\s*_\s*\{', r'\1_{', inner)

    # 4. 移除最外层无意义的花括号包裹：{ \frac{...}{...} } → \frac{...}{...}
    inner = re.sub(r'^\{\s*(\\.+?)\s*\}$', r'\1', inner)

    # 5. 运算符周围的多余空格（保留数学意义）
    inner = re.sub(r'\s*([=+\-*/<>])\s*', r'\1', inner)

    return inner


def _clean_latex_formulas(text: str) -> str:
    """清洗文本中的 LaTeX 公式块（$...$ 和 $$...$$）。"""
    if not text:
        return text

    math_blocks = []
    math_pattern = re.compile(r'(\$[^$]+\$|\$\$[^$]+\$\$)')

    def replace_math(match):
        raw = match.group(0)
        if raw.startswith('$$') and raw.endswith('$$'):
            inner = raw[2:-2]
            cleaned = _clean_latex_math(inner)
            math_blocks.append(f'$${cleaned}$$')
        else:
            inner = raw[1:-1]
            cleaned = _clean_latex_math(inner)
            math_blocks.append(f'${cleaned}$')
        return f"@@MATH_BLOCK_{len(math_blocks)-1}@@"

    text = math_pattern.sub(replace_math, text)

    for i, block in enumerate(math_blocks):
        text = text.replace(f"@@MATH_BLOCK_{i}@@", block)

    return text
