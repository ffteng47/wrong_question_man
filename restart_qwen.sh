#!/usr/bin/env bash
pkill -f "vllm serve" 2>/dev/null || true
sleep 2
source /home/tff/miniconda3/etc/profile.d/conda.sh
conda activate minerU_py312
cd /home/tff/software/LLM/wrong_answer_server
nohup vllm serve /home/tff/software/models/Qwen2.5-VL-7B-Instruct-AWQ \
    --port 8001 \
    --max-model-len 8192 \
    --gpu-memory-utilization 0.85 \
    --dtype half \
    --quantization awq \
    > logs/qwen.log 2>&1 &
sleep 2
echo "started"
