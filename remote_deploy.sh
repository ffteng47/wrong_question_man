#!/usr/bin/env bash
set -e
cd "$1"
echo "  Extract code..."
tar -xzf deploy.tar.gz
rm -f deploy.tar.gz

echo "  Stop old services..."
pkill -f "uvicorn app.main:app" 2>/dev/null || true
pkill -f "mineru-api" 2>/dev/null || true
pkill -f "vllm serve" 2>/dev/null || true
sleep 2

echo "  Start with start.sh..."
nohup bash start.sh > logs/start.log 2>&1 &

sleep 3
echo "  Done! Check logs/start.log for status"
