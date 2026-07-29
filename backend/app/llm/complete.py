"""한 번 호출해 JSON 하나를 받아오는 공용 경로.

대화는 스트리밍이지만 금액 추정처럼 '값 하나'만 필요한 곳은 스트리밍이 필요 없다.
백엔드(openai·local)마다 주소와 토큰 상한 이름이 달라서 여기 한곳에 모은다 —
안 그러면 기능을 하나 늘릴 때마다 갈래마다 다시 쓰게 되고,
실제로 그렇게 두는 바람에 openai 를 쓰는 동안 추정에는 LLM 이 아예 안 붙어 있었다.
"""
from __future__ import annotations

import json
from typing import TypeAlias

from .. import config
from ..security import redact_personal_data

JSONValue: TypeAlias = dict | list


def complete_json(prompt: str, max_tokens: int = 300, *,
                  force_object: bool = False) -> JSONValue | None:
    """첫 JSON 객체/배열을 돌려준다. 실패하면 None — 호출부가 규칙으로 폴백한다."""
    return complete_json_with_text(prompt, max_tokens, force_object=force_object)[0]


def complete_json_with_text(prompt: str, max_tokens: int = 300, *,
                            force_object: bool = False) -> tuple[JSONValue | None, str]:
    """(파싱한 JSON, 모델이 실제로 쓴 원문).

    파싱에 실패해도 원문은 돌려준다. 모델이 JSON 대신 문장으로 답하는 일이 있는데
    (gpt-4.1 에서 5회 중 1회 관측), 그 문장 자체는 멀쩡한 답인 경우가 많다.
    원문을 버리면 호출부는 "답을 만들지 못했어요" 말고 할 수 있는 게 없다.
    """
    backend = config.llm_backend()
    if backend == "offline":
        return None, ""
    try:
        text = _complete(backend, prompt, max_tokens, force_object=force_object)
    except Exception:
        return None, ""
    return _first_json_object(text), text


def _complete(backend: str, prompt: str, max_tokens: int, *,
              force_object: bool = False) -> str:
    # 모델 이름이 local이어도 URL이 원격이면 외부 전송이다.
    if config.llm_is_external(backend):
        prompt = redact_personal_data(prompt)

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

    payload = {
        "model": model,
        limit_key: max_tokens,
        "messages": [{"role": "user", "content": prompt}],
    }
    # 프롬프트로 "JSON만 출력" 이라고 시켜도 모델이 문장으로 답할 때가 있다. openai 는
    # 출력 형식을 강제할 수 있으므로 강제한다 — 최상위가 객체일 때만(배열은 이 모드가 거절).
    # local 서버는 이 인자를 모르는 구현이 많아 안 보낸다.
    if force_object and backend == "openai":
        payload["response_format"] = {"type": "json_object"}

    r = httpx.post(url, headers=headers, timeout=30, json=payload)
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
