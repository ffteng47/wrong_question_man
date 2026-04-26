import asyncio
import sys
sys.path.insert(0, '/home/tff/software/LLM/wrong_answer_server')

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

from app.services.pipeline import run_upload, run_extract
from app.config import settings

async def main():
    # 1. 生成测试图片
    img = Image.new('RGB', (800, 600), color='white')
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 24)
    except:
        font = ImageFont.load_default()

    text = """Math Test

1. Which of the following is an inverse proportion function?
   A. y = x + 1
   B. y = 1/x
   C. y = x^2
   D. y = 2x

Student answer: A
Correct answer: B
"""
    draw.text((50, 50), text, fill='black', font=font)

    test_path = Path(settings.originals_dir) / "test_e2e.jpg"
    test_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(test_path)
    print(f"Test image saved to {test_path}")

    # 2. Upload
    print("Running upload...")
    upload_resp = await run_upload(test_path, image_source="camera")
    print(f"Upload done: {len(upload_resp.blocks)} blocks")

    # 3. Extract with full-image ROI
    roi = [0, 0, 800, 600]
    print("Running extract...")
    extract_resp = await run_extract(
        image_id=upload_resp.image_id,
        originals_dir=settings.originals_dir,
        roi_bbox=roi,
        image_source="camera",
        enable_semantic=True,
    )
    print(f"Extract done!")
    print(f"  Subject: {extract_resp.record.subject}")
    print(f"  Type: {extract_resp.record.type}")
    print(f"  Problem: {extract_resp.record.problem[:100]}...")
    print(f"  Answer: {extract_resp.record.answer}")
    print(f"  Assets: {len(extract_resp.record.assets)}")

asyncio.run(main())
