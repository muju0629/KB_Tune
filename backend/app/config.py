"""환경 설정.

LLM_BACKEND 로 언어 생성 방식을 고른다. 기본은 'offline' — 유료 API를 절대 호출하지 않는다.
  - offline : 결정론 엔진 + 템플릿 문장 (비용 0, 키 불필요)  ← 기본
  - local   : 로컬 오픈소스 모델(OpenAI 호환: Bonsai/Ollama/llama.cpp) (비용 0)
  - claude  : Anthropic API (유료) — 명시적으로 켤 때만
  - openai  : OpenAI API — 명시적으로 켤 때만
"""
import os
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()

# 키를 따로 보관한 파일이 있으면 함께 읽는다(저장소 밖에 두고 참조만).
# 값은 이 프로세스의 환경변수로만 들어가고 코드나 로그에 남지 않는다.
_extra_env = os.getenv("EXTRA_ENV_FILE")
if _extra_env and Path(_extra_env).expanduser().is_file():
    load_dotenv(Path(_extra_env).expanduser(), override=False)

# 기본값 offline → 아무 설정 없이 실행하면 유료 API를 절대 부르지 않음.
LLM_BACKEND = os.getenv("LLM_BACKEND", "offline").lower()

# --- 로컬 모델(OpenAI 호환 서버) ---
# Ollama: http://localhost:11434/v1 · Bonsai(llama-server): http://localhost:8080/v1
LOCAL_LLM_BASE_URL = os.getenv("LOCAL_LLM_BASE_URL", "http://localhost:11434/v1")
LOCAL_LLM_MODEL = os.getenv("LOCAL_LLM_MODEL", "qwen2.5:3b")

# --- Claude(유료, 선택) ---
CLAUDE_MODEL = os.getenv("KB_TUNE_MODEL", "claude-opus-5")

# --- OpenAI(선택) ---
OPENAI_BASE_URL = os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1")
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-5.4")


def api_key() -> str | None:
    return os.getenv("ANTHROPIC_API_KEY") or None


def openai_key() -> str | None:
    """OPENAI_API_KEY 가 표준이지만, 키 파일이 OPENAI 로만 적어둔 경우도 받아준다."""
    return os.getenv("OPENAI_API_KEY") or os.getenv("OPENAI") or None


def llm_backend() -> str:
    """유효한 백엔드를 반환. 키가 필요한 백엔드인데 키가 없으면 offline으로 강등."""
    if LLM_BACKEND == "claude" and api_key() is None:
        return "offline"
    if LLM_BACKEND == "openai" and openai_key() is None:
        return "offline"
    if LLM_BACKEND in ("offline", "local", "claude", "openai"):
        return LLM_BACKEND
    return "offline"


def llm_enabled() -> bool:
    """언어 생성에 실제 모델을 쓰는지(=offline이 아닌지)."""
    return llm_backend() != "offline"
