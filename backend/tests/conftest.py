"""테스트는 네트워크도 키도 없이 돌아야 한다.

`.env` 에 `LLM_BACKEND=openai` 를 걸어 두고 개발하는 동안, 그 값이 그대로 테스트에도
새어 들어와 `/api/coach` 같은 경로가 진짜 API를 호출했다. 느려지는 것도 문제지만
CI나 심사자 환경에서는 키가 없어 결과가 달라진다.

그래서 기본을 offline 로 고정한다. 특정 백엔드 동작을 봐야 하는 테스트는
`monkeypatch.setattr(config, "llm_backend", lambda: "openai")` 로 그 테스트 안에서만 바꾼다.
"""
from __future__ import annotations

import os

import pytest


@pytest.fixture(autouse=True, scope="session")
def _force_offline_backend() -> None:
    os.environ["LLM_BACKEND"] = "offline"

    from app import config

    config.LLM_BACKEND = "offline"
