"""한 번 호출해 JSON 하나를 받아오는 공용 경로.

대화는 스트리밍이지만 금액 추정처럼 '값 하나'만 필요한 곳은 스트리밍이 필요 없다.
백엔드(claude·openai·local)마다 호출 방식이 달라서 여기 한곳에 모은다 —
안 그러면 기능을 하나 늘릴 때마다 세 갈래를 다시 쓰게 되고,
실제로 그렇게 두는 바람에 openai 를 쓰는 동안 추정에는 LLM 이 아예 안 붙어 있었다.
"""
from __future__ import annotations

import json
from typing import TypeAlias

from .. import config
from ..security import redact_personal_data

JSONValue: TypeAlias = dict | list


def complete_json(prompt: str, max_tokens: int = 300) -> JSONValue | None:
    """첫 JSON 객체/배열을 돌려준다. 실패하면 None — 호출부가 규칙으로 폴백한다."""
    backend = config.llm_backend()
    if backend == "offline":
        return None
    try:
        return _first_json_object(_complete(backend, prompt, max_tokens))
    except Exception:
        return None


def _complete(backend: str, prompt: str, max_tokens: int) -> str:
    # 모델 이름이 local이어도 URL이 원격이면 외부 전송이다.
    if config.llm_is_external(backend):
        prompt = redact_personal_data(prompt)

    if backend == "claude":
        import anthropic
        r = anthropic.Anthropic().messages.create(
            model=config.CLAUDE_MODEL, max_tokens=max_tokens,
            messages=[{"role": "user", "content": prompt}],
        )
        return "".join(b.text for b in r.content if b.type == "text")

    import httpx
    if backend == "openai":
        url = config.OPENAI_BASE_URL.rstrip("/") + "/chat/completions"
        headers = {"Authorization": f"Bearer {config.openai_key()}"}
        model = config.OPENAI_MODEL
        # 최신 OpenAI 모델은 max_tokens 를 거절한다(400 unsupported_parameter).
        # 이걸 보내는 동안 openai 백엔드에서는 complete_json 이 매번 실패해,
        # 추정·분류가 규칙으로만 돌면서도 이유가 드러나지 않았다.
        limit_key = "max_completion_tokens"
    else:                                   # local — OpenAI 호환 서버
        url = config.LOCAL_LLM_BASE_URL.rstrip("/") + "/chat/completions"
        headers = {}
        model = config.LOCAL_LLM_MODEL
        # Ollama·llama.cpp 등은 아직 예전 이름만 받는다.
        limit_key = "max_tokens"

    r = httpx.post(url, headers=headers, timeout=30, json={
        "model": model,
        limit_key: max_tokens,
        "messages": [{"role": "user", "content": prompt}],
    })
    r.raise_for_status()
    return r.json()["choices"][0]["message"]["content"]


def _first_json_object(text: str) -> JSONValue | None:
    """모델이 설명을 붙여도 가장 먼저 완결된 JSON 객체/배열만 꺼낸다."""
    decoder = json.JSONDecoder()
    starts = [i for i, char in enumerate(text) if char in "{["]
    for start in starts:
        try:
            obj, _end = decoder.raw_decode(text[start:])
        except (TypeError, ValueError, json.JSONDecodeError):
            continue
        if isinstance(obj, (dict, list)):
            return obj
    return None
