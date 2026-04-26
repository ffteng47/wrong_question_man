from transformers import Qwen2_5_VLForConditionalGeneration, AutoProcessor, AutoTokenizer
import torch

model_path = "/home/tff/software/models/Qwen2.5-VL-7B-Instruct-AWQ"
print("Loading model...")
model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
    model_path,
    dtype=torch.float16,
    device_map="auto",
    trust_remote_code=True
)
processor = AutoProcessor.from_pretrained(model_path, trust_remote_code=True)
print("Model loaded")

messages = [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "What is 2+2? Answer in JSON with key 'answer'."}
]

text = processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
inputs = processor(text=[text], return_tensors="pt").to(model.device)

print("Generating...")
with torch.no_grad():
    outputs = model.generate(**inputs, max_new_tokens=128, temperature=0.1, do_sample=True)

response = processor.batch_decode(outputs, skip_special_tokens=True)[0]
print("Response:")
print(response)
