from transformers import Qwen2_5_VLForConditionalGeneration, AutoProcessor
import torch

model_path = "/home/tff/software/models/Qwen2.5-VL-7B-Instruct-AWQ"
print("Loading model...")
model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
    model_path,
    torch_dtype=torch.float16,
    device_map="auto",
    trust_remote_code=True
)
print("Model loaded on", model.device)
print("GPU memory:", torch.cuda.memory_allocated() / 1e9, "GB")
