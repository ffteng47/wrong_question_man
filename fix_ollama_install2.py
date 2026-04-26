with open('/tmp/ollama_install.sh') as f:
    data = f.read()

# Prepend user bindir before the loop
old_loop = "for BINDIR in /usr/local/bin /usr/bin /bin; do"
new_loop = "BINDIR=/home/tff/.local/bin\n" + old_loop
data = data.replace(old_loop, new_loop)

# Remove sudo assignment
data = data.replace('SUDO="sudo"', 'SUDO=""')

with open('/tmp/ollama_install.sh', 'w') as f:
    f.write(data)
print('Done')
