#!/usr/bin/env bash
pkill -f "uvicorn app.main:app" 2>/dev/null || true
pkill -f "mineru-api" 2>/dev/null || true
pkill -f "vllm serve" 2>/dev/null || true
sleep 2
cd /home/tff/software/LLM/wrong_answer_server
mkdir -p logs
source /home/tff/miniconda3/etc/profile.d/conda.sh
conda activate minerU_py312
nohup bash start.sh > logs/start.log 2>&1 &
sleep 3
echo "started"
