with open('/home/tff/software/LLM/wrong_answer_server/app/main.py', 'r', encoding='utf-8') as f:
    data = f.read()

# Fix garbled Chinese characters
lines = data.split('\n')
for i, line in enumerate(lines):
    if '??????????????' in line:
        lines[i] = '    logger.info("错题系统服务端启动")'
    if '??????' in line:
        lines[i] = line.replace('??????', '本地推理')

data = '\n'.join(lines)

with open('/home/tff/software/LLM/wrong_answer_server/app/main.py', 'w', encoding='utf-8') as f:
    f.write(data)

print('Fixed')
