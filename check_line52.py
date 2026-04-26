with open('/home/tff/software/LLM/wrong_answer_server/app/core/qwen_client.py', 'rb') as f:
    data = f.read()
lines = data.split(b'\n')
print('Line 52 (bytes):', repr(lines[51]))
print('Total lines:', len(lines))
