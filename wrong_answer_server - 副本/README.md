# 错题系统 - 服务端

## 目录结构
```
wrong_answer_server/
├── app/
│   ├── main.py              # FastAPI 入口
│   ├── config.py            # 配置（路径、端口、模型）
│   ├── api/
│   │   ├── upload.py        # POST /api/v1/upload
│   │   ├── extract.py       # POST /api/v1/extract
│   │   ├── save.py          # POST /api/v1/save & GET /api/v1/records
│   │   └── tasks.py         # GET /api/v1/tasks/{task_id}
│   ├── core/
│   │   ├── preprocess.py    # OpenCV 图像预处理
│   │   ├── mineru_client.py # MinerU API 调用
│   │   ├── qwen_client.py   # Qwen2.5-VL vLLM 调用
│   │   └── asset_extractor.py # Pillow 图片裁切
│   ├── models/
│   │   └── schema.py        # Pydantic 模型（wrong_answer_record）
│   └── services/
│       └── pipeline.py      # 两阶段流水线编排
├── storage/                 # 运行时生成，不提交 git
│   ├── originals/           # 上传原图
│   ├── rois/                # ROI 裁切图
│   └── assets/              # 题目图片块
├── tests/
│   ├── test_upload.py
│   └── test_extract.py
├── requirements.txt
└── start.sh                 # 一键启动脚本
```

## 快速启动

```bash
# 1. 安装依赖
pip install -r requirements.txt

# 2. 启动 MinerU API（另一个终端）
mineru-api --port 8000 -b vlm-vllm-async-engine --enable-vlm-preload

# 3. 启动 Qwen2.5-VL vLLM（另一个终端，MinerU 空闲后再启动）
vllm serve Qwen/Qwen2.5-VL-7B-Instruct-AWQ \
  --port 8001 \
  --max-model-len 32768 \
  --gpu-memory-utilization 0.60 \
  --dtype half \
  --quantization awq

# 4. 启动 FastAPI 中间层
cd wrong_answer_server
uvicorn app.main:app --host 0.0.0.0 --port 9000 --workers 1 --reload
```
