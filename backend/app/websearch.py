"""웹 검색 — 앱 데이터로 답할 수 없는 질문만 여기로 온다.

이 경로는 다른 경로와 성격이 다르다. `/api/chat` 은 질문을 `financial_intent_text()` 로
줄여서 보내지만, 검색은 "이태원 맛집" 처럼 원문이 있어야 답이 나온다. 그래서 나가는 것을
'질문 한 줄'로 못박고, 예산·일정·이름은 이 경로에 아예 싣지 않는다.

검색은 별도 검색 API 없이 OpenAI Responses API 의 `web_search` 도구로 한다.
모델이 스스로 검색어를 정하고, 결과를 읽고, 한국어 문장으로 정리해 돌려준다.
검색 결과 목록을 그대로 붙이는 것보다 앱의 말투에 맞고, 키도 이미 있는 것 하나면 된다.
"""
from __future__ import annotations

import re
from typing import Any

import httpx

from . import config

_TIMEOUT = 30.0

# 앱의 말투와 경계를 지키게 하는 지시. 검색 결과를 요약하는 역할만 준다.
_INSTRUCTIONS = """너는 소비 계획 앱 'KB Tune'의 도우미다. 사용자가 앱 데이터로는 답할 수 없는 것을
물어서 웹 검색으로 답하는 중이다.

- 해요체로, 세 문장 안팎으로 짧게 답한다.
- 검색으로 확인한 것만 말한다. 확인 못 한 건 모른다고 한다.
- 사용자의 예산·일정·소비 내역은 너에게 주어지지 않았다. 아는 척하지 않는다.
- 돈이 드는 이야기라면 마지막에 한 줄로 "예산에 넣어 볼까요?"처럼 앱으로 돌아올 길을 열어 준다.
- 굵게·기울임·목록 기호·표·머리글을 쓰지 않는다. 앱 말풍선은 마크다운을 해석하지 않고
  글자 그대로 보여줘서 별표가 그대로 노출된다. 평범한 문장으로만 쓴다.

출처 표기는 평소대로 하면 된다. 앱이 본문에서 걷어내고 '계산 근거' 쪽에 따로 붙인다."""


def enabled() -> bool:
    """OpenAI 키가 물려 있을 때만 켠다."""
    return config.openai_key() is not None


def responses_call(query: str, instructions: str | None = None,
                   timeout: float = _TIMEOUT) -> dict[str, Any] | None:
    """OpenAI Responses API + web_search 를 부르고 원본 응답을 돌려준다. 실패하면 None.

    금액 찾기(`llm/search.py`)도 같은 API 를 같은 도구로 부른다. 호출과 응답 파싱을
    두 벌 두면 한쪽만 고치게 되므로 여기 한 곳에 둔다 — 갈리는 건 지시문과 대기 시간뿐이다.
    """
    payload: dict[str, Any] = {
        "model": config.OPENAI_MODEL,
        "input": query,
        "tools": [{"type": "web_search"}],
    }
    if instructions:
        payload["instructions"] = instructions
    try:
        r = httpx.post(config.OPENAI_BASE_URL.rstrip("/") + "/responses",
                       headers={"Authorization": f"Bearer {config.openai_key()}"},
                       timeout=timeout, json=payload)
        return r.json() if r.status_code == 200 else None
    except Exception:
        return None


def search(query: str) -> dict[str, Any]:
    """검색해서 정리된 한국어 답과 출처를 돌려준다.

    반환: {"answer": str, "sources": [str, ...]} — 실패하면 answer 가 빈 문자열.
    """
    if not enabled():
        return {"answer": "", "sources": []}

    data = responses_call(query, _INSTRUCTIONS)
    if data is None:
        return {"answer": "", "sources": []}

    return {"answer": answer_of(data), "sources": sources_of(data)}


def answer_of(data: dict[str, Any]) -> str:
    """모델이 쓴 본문만 뽑는다. 검색 호출 항목은 건너뛴다."""
    text = data.get("output_text")
    if isinstance(text, str) and text.strip():
        return text.strip()

    parts: list[str] = []
    for item in data.get("output", []) or []:
        if item.get("type") != "message":
            continue
        for block in item.get("content", []) or []:
            if block.get("type") in ("output_text", "text"):
                value = block.get("text")
                if isinstance(value, str):
                    parts.append(value)
    return _plain(("\n".join(parts)).strip())


# 인용을 못 하게 막으면 링크 메타데이터까지 같이 사라진다. 그래서 모델은 평소대로
# 인용하게 두고, 말풍선에 들어갈 본문에서만 마크다운 기호를 걷어낸다.
_LINK = re.compile(r"\(?\[([^\]]*)\]\((https?://[^)]*)\)\)?")
_EMPHASIS = re.compile(r"(\*\*|__|\*|`)")


def _plain(text: str) -> str:
    text = _LINK.sub("", text)          # ([michelin.com](https://…)) 통째로 제거
    text = _EMPHASIS.sub("", text)      # **굵게** 같은 기호 제거
    text = re.sub(r"[ \t]{2,}", " ", text)
    text = re.sub(r" +([,.!?])", r"\1", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return "\n".join(line.rstrip() for line in text.split("\n")).strip()


def sources_of(data: dict[str, Any]) -> list[str]:
    """본문에 붙은 인용 링크. 중복은 앞의 것만 남긴다."""
    seen: list[str] = []
    for item in data.get("output", []) or []:
        for block in item.get("content", []) or []:
            for note in block.get("annotations", []) or []:
                link = note.get("url")
                if isinstance(link, str) and link and link not in seen:
                    seen.append(link)
    return seen[:3]
