"""환경 설정.

LLM_BACKEND 로 언어 생성 방식을 고른다. 기본은 'offline' — 유료 API를 절대 호출하지 않는다.
  - offline : 결정론 엔진 + 템플릿 문장 (비용 0, 키 불필요)  ← 기본
  - local   : 로컬 오픈소스 모델(OpenAI 호환: Bonsai/Ollama/llama.cpp) (비용 0)
  - claude  : Anthropic API (유료) — 명시적으로 켤 때만
"""
import os

from dotenv import load_dotenv

load_dotenv()

# 기본값 offline → 아무 설정 없이 실행하면 유료 API를 절대 부르지 않음.
LLM_BACKEND = os.getenv("LLM_BACKEND", "offline").lower()

# --- 로컬 모델(OpenAI 호환 서버) ---
# Ollama: http://localhost:11434/v1 · Bonsai(llama-server): http://localhost:8080/v1
LOCAL_LLM_BASE_URL = os.getenv("LOCAL_LLM_BASE_URL", "http://localhost:11434/v1")
LOCAL_LLM_MODEL = os.getenv("LOCAL_LLM_MODEL", "qwen2.5:3b")

# --- Claude(유료, 선택) ---
CLAUDE_MODEL = os.getenv("KB_TUNE_MODEL", "claude-opus-5")


def api_key() -> str | None:
    return os.getenv("ANTHROPIC_API_KEY") or None


def llm_backend() -> str:
    """유효한 백엔드를 반환. claude를 골랐지만 키가 없으면 offline으로 강등."""
    if LLM_BACKEND == "claude" and api_key() is None:
        return "offline"
    if LLM_BACKEND in ("offline", "local", "claude"):
        return LLM_BACKEND
    return "offline"


def llm_enabled() -> bool:
    """언어 생성에 실제 모델을 쓰는지(=offline이 아닌지)."""
    return llm_backend() != "offline"
