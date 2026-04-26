import asyncio
import sys
sys.path.insert(0, '/home/tff/software/LLM/wrong_answer_server')

from app.core.qwen_client import analyze_semantic

async def main():
    ocr_text = """
    1. 下列函数中，是反比例函数的是（  ）
    A. y = x + 1
    B. y = 1/x
    C. y = x^2
    D. y = 2x
    学生答案：A
    正确答案：B
    """
    result = await analyze_semantic(ocr_text)
    print("Subject:", result.get("subject"))
    print("Type:", result.get("type"))
    print("Answer:", result.get("answer"))
    print("Error analysis:", result.get("error_analysis"))

asyncio.run(main())
