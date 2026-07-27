#!/usr/bin/env bash
# 로컬 실행: 키가 없어도 동작(엔진 + 템플릿). 키가 있으면 Claude 코칭 사용.
set -e
cd "$(dirname "$0")"

if [ ! -d .venv ]; then
  python3 -m venv .venv
  ./.venv/bin/pip install -q -r requirements.txt
fi

# 기본은 루프백만 — 0.0.0.0 으로 띄우면 같은 Wi-Fi의 아무나 API를 부를 수 있다.
# 실기기로 데모할 때만 HOST=0.0.0.0 로 열고, 그때는 KB_TUNE_API_KEY 를 함께 건다.
HOST="${HOST:-127.0.0.1}"
# --reload 는 개발용(파일 감시·리로더 프로세스). 배포에서는 RELOAD=0.
[ "${RELOAD:-1}" = "1" ] && RELOAD_FLAG="--reload" || RELOAD_FLAG=""

exec ./.venv/bin/uvicorn app.main:app --host "$HOST" --port 8000 $RELOAD_FLAG
