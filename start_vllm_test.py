import subprocess
import sys

cmd = [
    "vllm", "serve", "/home/tff/software/models/Qwen2.5-VL-7B-Instruct-AWQ",
    "--port", "8001",
    "--max-model-len", "2048",
    "--gpu-memory-utilization", "0.55",
    "--max-num-seqs", "1",
    "--enforce-eager",
    "--dtype", "half",
    "--quantization", "awq"
]

env = {
    "VLLM_ATTENTION_BACKEND": "XFORMERS",
    "PATH": "/home/tff/miniconda3/envs/minerU_py312/bin:/usr/local/cuda/bin:/usr/bin:/bin",
    "CUDA_HOME": "/usr/local/cuda"
}

with open("/home/tff/software/LLM/wrong_answer_server/logs/qwen.log", "w") as f:
    proc = subprocess.Popen(cmd, stdout=f, stderr=f, env=env)
    print(f"Started vLLM with PID {proc.pid}")
