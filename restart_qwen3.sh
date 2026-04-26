#!/bin/bash
ssh -p 22 tff@192.168.41.177 'bash -s' << 'EOF'
set -e
source /home/tff/miniconda3/etc/profile.d/conda.sh
conda activate minerU_py312
export VLLM_ATTENTION_BACKEND=XFORMERS
cd /home/tff/software/LLM/wrong_answer_server
pkill -f "vllm serve" || true
sleep 2
nohup vllm serve /home/tff/software/models/Qwen2.5-VL-7B-Instruct-AWQ \
  --port 8001 \
  --max-model-len 4096 \
  --gpu-memory-utilization 0.50 \
  --max-num-seqs 1 \
  --enforce-eager \
  --dtype half \
  --quantization awq \
  > logs/qwen.log 2>&1 &
echo "Qwen restarted with PID $!"
EOF
