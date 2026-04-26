import re
with open('/tmp/ollama_install.sh') as f:
    data = f.read()
data = data.replace('BINDIR=/usr/local/bin', 'BINDIR=/home/tff/.local/bin')
data = data.replace('sudo ', '')
with open('/tmp/ollama_install.sh', 'w') as f:
    f.write(data)
print('Done')
