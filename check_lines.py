with open('/home/tff/software/LLM/wrong_answer_server/app/core/qwen_client.py', 'rb') as f:
    data = f.read()
lines = data.split(b'\n')
for i in range(48, 56):
    print(f'Line {i+1}: {repr(lines[i])}')
