with open('/tmp/ollama_install.sh') as f:
    data = f.read()

# Replace the loop to use user bindir first
old_loop = "for BINDIR in /usr/local/bin /usr/bin /bin; do"
new_loop = "for BINDIR in /home/tff/.local/bin /usr/local/bin /usr/bin /bin; do"
data = data.replace(old_loop, new_loop)

# Remove sudo assignment
data = data.replace('SUDO="sudo"', 'SUDO=""')

# Remove the standalone BINDIR line if exists from previous fix
data = data.replace("BINDIR=/home/tff/.local/bin\n" + old_loop + "\n", new_loop + "\n")

with open('/tmp/ollama_install.sh', 'w') as f:
    f.write(data)
print('Done')
