#!/usr/bin/env bash
# 错题系统一键启动脚本
# 用法: bash start.sh [--no-mineru]
set -e

# 激活 conda 环境
source /home/tff/miniconda3/etc/profile.d/conda.sh
conda activate minerU_py312

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

START_MINERU=true

for arg in "$@"; do
  case $arg in
    --no-mineru) START_MINERU=false ;;
  esac
done

echo "========================================"
echo "  错题系统服务端启动"
echo "========================================"

# 清理旧进程（防止端口占用）
echo "[0/2] 清理旧进程..."
pkill -f "uvicorn app.main:app" 2>/dev/null || true
pkill -f "mineru-api" 2>/dev/null || true
pkill -f "vllm serve" 2>/dev/null || true
sleep 2

# 1. MinerU API
if $START_MINERU; then
  echo "[1/2] 启动 MinerU API (port 8000)..."
  nohup mineru-api \
    --port 8000 \
    -b pipeline \
    > logs/mineru.log 2>&1 &
  echo "  PID=$! → logs/mineru.log"
  sleep 5
fi

# 2. FastAPI 中间层（内置 Qwen 本地推理）
echo "[2/2] 启动 FastAPI (port 9000)..."
mkdir -p logs
uvicorn app.main:app \
  --host 0.0.0.0 \
  --port 9000 \
  --workers 1 \
  --reload \
  --log-level info
