"""
集成测试 — 上传 + 提取流程（使用 httpx TestClient，不需要真实模型）
运行：cd wrong_answer_server && pytest tests/ -v
"""
import pytest
import json
from pathlib import Path
from unittest.mock import AsyncMock, patch, MagicMock
from fastapi.testclient import TestClient

# ── 创建测试用假图（不依赖真实试卷）────────────────────────────────────────
def _make_test_image(tmp_path: Path) -> Path:
    """生成一张纯白 PNG 用于测试"""
    try:
        from PIL import Image
        img = Image.new("RGB", (800, 1200), color=(255, 255, 255))
        p = tmp_path / "test_page.jpg"
        img.save(str(p))
        return p
    except ImportError:
        # Pillow 未安装时用随机字节模拟
        p = tmp_path / "test_page.jpg"
        p.write_bytes(b"\xff\xd8\xff" + b"\x00" * 100)
        return p


MOCK_BLOCKS = [
    {"id": "blk_0", "type": "title",  "content": "1. 下列函数中，哪些是一次函数？",
     "bbox": [100, 100, 900, 160], "score": 0.95},
    {"id": "blk_1", "type": "text",   "content": "(3) $y=(x+3)^2-x^2$",
     "bbox": [100, 200, 900, 260], "score": 0.92},
]

MOCK_SEMANTIC = {
    "type": "计算题",
    "seq": 1,
    "sub_seq": "(3)",
    "problem": "下列函数中，哪些是一次函数？哪些是二次函数？\n\n(3) $y=(x+3)^2-x^2$",
    "answer": "$y=6x+9$，是一次函数",
    "solution": "展开得：$y=(x+3)^2-x^2=x^2+6x+9-x^2=6x+9$\n\n最高次数为 1，所以是一次函数。",
    "subject": "数学",
    "grade": "初三",
    "chapters": ["一次函数", "二次函数"],
    "knowledge_points": ["函数化简", "多项式展开", "一次函数判定"],
    "key_points": [
        "完全平方公式展开：$(x+3)^2=x^2+6x+9$",
        "合并同类项后判断最高次数",
    ],
    "difficulty": 3,
    "difficulty_desc": "需展开化简后判断，易误判为二次函数",
    "error_analysis": {
        "student_answer": "二次函数",
        "error_category": "概念混淆",
        "error_desc": "未展开直接看到平方项误判",
        "prevention_tip": "必须先展开合并同类项再判断最高次数",
    },
    "tags": ["函数", "一次函数", "易错"],
}


@pytest.fixture
def client(tmp_path, monkeypatch):
    """构建带 mock 的 TestClient"""
    # 重定向 storage 到 tmp_path
    monkeypatch.setattr("app.config.settings.storage_root", tmp_path / "storage")
    (tmp_path / "storage" / "originals").mkdir(parents=True)
    (tmp_path / "storage" / "rois").mkdir(parents=True)
    (tmp_path / "storage" / "assets").mkdir(parents=True)
    (tmp_path / "storage" / "records").mkdir(parents=True)

    from app.main import app
    return TestClient(app, raise_server_exceptions=True)


@patch("app.core.mineru_client.parse_image", new_callable=AsyncMock)
@patch("app.core.preprocess.preprocess_image")
def test_upload(mock_preprocess, mock_mineru, client, tmp_path):
    from app.models.schema import ContentBlock

    mock_preprocess.return_value = (
        tmp_path / "storage" / "originals" / "proc_test.jpg", 800, 1200
    )
    mock_mineru.return_value = (
        [ContentBlock(**b) for b in MOCK_BLOCKS], 0.92
    )

    img_path = _make_test_image(tmp_path)
    with open(img_path, "rb") as f:
        resp = client.post(
            "/api/v1/upload",
            files={"image": ("test_page.jpg", f, "image/jpeg")},
            data={"image_source": "camera"},
        )

    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert "image_id" in data
    assert data["width_px"] == 800
    assert data["height_px"] == 1200
    assert len(data["preview_blocks"]) == 2
    print(f"\n✅ upload: image_id={data['image_id']}, blocks={len(data['preview_blocks'])}")


@patch("app.core.qwen_client.analyze_semantic", new_callable=AsyncMock)
@patch("app.core.mineru_client.parse_image", new_callable=AsyncMock)
@patch("app.core.preprocess.preprocess_image")
def test_extract(mock_preprocess, mock_mineru, mock_qwen, client, tmp_path):
    from app.models.schema import ContentBlock

    # 先 upload 建立 image_id
    mock_preprocess.return_value = (
        tmp_path / "storage" / "originals" / "proc_test.jpg", 800, 1200
    )
    mock_mineru.return_value = (
        [ContentBlock(**b) for b in MOCK_BLOCKS], 0.92
    )
    mock_qwen.return_value = MOCK_SEMANTIC

    img_path = _make_test_image(tmp_path)
    with open(img_path, "rb") as f:
        up = client.post(
            "/api/v1/upload",
            files={"image": ("test_page.jpg", f, "image/jpeg")},
            data={"image_source": "camera"},
        )
    image_id = up.json()["image_id"]

    # 写 blocks 缓存（模拟 run_upload 写的文件）
    cache = tmp_path / "storage" / "originals" / f"{image_id}_blocks.json"
    cache.write_text(json.dumps(MOCK_BLOCKS), encoding="utf-8")

    # 写原图占位
    orig = tmp_path / "storage" / "originals" / f"{image_id}.jpg"
    _make_test_image(tmp_path)
    import shutil
    shutil.copy(img_path, orig)

    # extract
    resp = client.post("/api/v1/extract", json={
        "image_id": image_id,
        "roi_bbox": [100, 100, 900, 300],
        "image_source": "camera",
        "enable_semantic": True,
    })

    assert resp.status_code == 200, resp.text
    rec = resp.json()["record"]
    assert rec["subject"] == "数学"
    assert rec["grade"] == "初三"
    assert rec["difficulty"] == 3
    assert "6x+9" in rec["answer"]
    print(f"\n✅ extract: subject={rec['subject']}, type={rec['type']}, difficulty={rec['difficulty']}")


def test_health(client):
    resp = client.get("/health")
    # 上游服务未运行，status=degraded 是预期的
    assert resp.status_code == 200
    data = resp.json()
    assert "status" in data
    assert "mineru_ok" in data
    print(f"\n✅ health: {data}")
