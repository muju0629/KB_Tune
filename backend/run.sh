#!/usr/bin/env bash
# 로컬 실행: 키가 없어도 동작(엔진 + 템플릿). 키가 있으면 Claude 코칭 사용.
set -e
cd "$(dirname "$0")"

if [ ! -d .venv ]; then
  python3 -m venv .venv
  ./.venv/bin/pip install -q -r requirements.txt
fi

exec ./.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
