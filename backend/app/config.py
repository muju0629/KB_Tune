"""환경 설정.

LLM_BACKEND 로 언어 생성 방식을 고른다. 기본은 'offline' — 유료 API를 절대 호출하지 않는다.
  - offline : 결정론 엔진 + 템플릿 문장 (비용 0, 키 불필요)  ← 기본
  - local   : 로컬 오픈소스 모델(OpenAI 호환: Bonsai/Ollama/llama.cpp) (비용 0)
  - claude  : Anthropic API (유료) — 명시적으로 켤 때만
  - openai  : OpenAI API — 명시적으로 켤 때만
"""
import os
from pathlib import Path
from urllib.parse import urlparse

from dotenv import load_dotenv

load_dotenv()

# 키를 따로 보관한 파일이 있으면 함께 읽는다(저장소 밖에 두고 참조만).
# 값은 이 프로세스의 환경변수로만 들어가고 코드나 로그에 남지 않는다.
_extra_env = os.getenv("EXTRA_ENV_FILE")
if _extra_env and Path(_extra_env).expanduser().is_file():
    load_dotenv(Path(_extra_env).expanduser(), override=False)

# 기본값 offline → 아무 설정 없이 실행하면 유료 API를 절대 부르지 않음.
LLM_BACKEND = os.getenv("LLM_BACKEND", "offline").lower()


def _checked_llm_url(raw: str, var: str) -> str:
    """LLM 엔드포인트는 https 또는 루프백만 허용한다.

    이 통로로 가처분소득·카드 청구액·일정 제목이 나간다. 환경변수 오설정 하나로
    평문 http나 엉뚱한 호스트로 흐르면 그대로 유출이라, 뜰 때 막는다(fail-closed).
    LAN에 둔 로컬 모델 서버를 http로 쓰려면 KB_TUNE_ALLOW_INSECURE_LLM_URL=1.
    """
    if os.getenv("KB_TUNE_ALLOW_INSECURE_LLM_URL", "").lower() in ("1", "true", "yes"):
        return raw
    if raw.startswith("https://") or (urlparse(raw).hostname or "") in ("localhost", "127.0.0.1", "::1"):
        return raw
    raise ValueError(
        f"{var} 는 https 여야 합니다(현재: {raw}). 루프백이 아닌 평문 http로는 재무 데이터를 "
        "보내지 않습니다. 로컬 네트워크의 모델 서버를 쓰려면 KB_TUNE_ALLOW_INSECURE_LLM_URL=1."
    )


def _is_loopback_url(raw: str) -> bool:
    return (urlparse(raw).hostname or "").lower() in ("localhost", "127.0.0.1", "::1")


# --- 로컬 모델(OpenAI 호환 서버) ---
# Ollama: http://localhost:11434/v1 · Bonsai(llama-server): http://localhost:8080/v1
LOCAL_LLM_BASE_URL = _checked_llm_url(
    os.getenv("LOCAL_LLM_BASE_URL", "http://localhost:11434/v1"), "LOCAL_LLM_BASE_URL")
LOCAL_LLM_MODEL = os.getenv("LOCAL_LLM_MODEL", "qwen2.5:3b")

# --- Claude(유료, 선택) ---
CLAUDE_MODEL = os.getenv("KB_TUNE_MODEL", "claude-opus-5")

# --- OpenAI(선택) ---
OPENAI_BASE_URL = _checked_llm_url(
    os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1"), "OPENAI_BASE_URL")
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-5.4")


# --- 보안 ---
# 요청 인증 키. 비워두면 무인증으로 동작한다(설정 없이 바로 실행 가능해야 하므로).
# 공개된 곳에 배포할 때는 반드시 채운다.
def api_auth_key() -> str | None:
    return os.getenv("KB_TUNE_API_KEY") or None


# 브라우저에서 부를 일이 없으면 비워둔다(네이티브 앱은 CORS 영향을 받지 않음).
ALLOWED_ORIGINS = [o.strip() for o in os.getenv("KB_TUNE_ALLOWED_ORIGINS", "").split(",") if o.strip()]

# 본문 상한. 기본 2MB — base64 이미지 한 장이 들어갈 만큼만.
MAX_BODY_BYTES = int(os.getenv("KB_TUNE_MAX_BODY_BYTES", "2000000"))

# 프록시(Render 등) 뒤일 때만 켠다. 켜면 X-Forwarded-For 를 클라이언트 IP로 믿는다.
TRUST_PROXY = os.getenv("KB_TUNE_TRUST_PROXY", "").lower() in ("1", "true", "yes")

# 속도 제한(분당). LLM 쪽은 비용이 걸려 있어 따로 잡는다.
RATE_LLM = int(os.getenv("KB_TUNE_RATE_LLM", "20"))              # 클라이언트당 / 60초
RATE_LLM_GLOBAL = int(os.getenv("KB_TUNE_RATE_LLM_GLOBAL", "200"))  # 전체 합 / 60초
RATE_EVAL = int(os.getenv("KB_TUNE_RATE_EVAL", "3"))             # 클라이언트당 / 300초
RATE_EVAL_GLOBAL = int(os.getenv("KB_TUNE_RATE_EVAL_GLOBAL", "20"))  # 전체 합 / 300초
RATE_CHEAP = int(os.getenv("KB_TUNE_RATE_CHEAP", "120"))         # 클라이언트당 / 60초


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


def llm_is_external(backend: str | None = None) -> bool:
    """모델 호출이 이 서버 기기 밖으로 나가는지.

    `local`은 제품명이 아니라 OpenAI 호환 프로토콜 선택지다. URL이 원격 HTTPS면 실제로는
    외부 전송이므로 동의·비식별화 경계를 똑같이 적용한다.
    """
    selected = backend or llm_backend()
    if selected in ("claude", "openai"):
        return True
    if selected == "local":
        return not _is_loopback_url(LOCAL_LLM_BASE_URL)
    return False
