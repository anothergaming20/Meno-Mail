#!/bin/bash
export PATH="/usr/local/opt/node@22/bin:$PATH"
echo "MenoMail Agent Status — $(date)"
echo "OpenClaw: $(openclaw --version 2>/dev/null | head -1)"
echo "bot.py: $(curl -sf http://127.0.0.1:8080/health 2>/dev/null || echo 'not running')"
echo "api_server: $(curl -sf http://127.0.0.1:8888/health 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status","?"))' 2>/dev/null || echo 'not running')"
