"""골든 케이스 — 엔진의 결정론적 정합성 검증.

입력→출력이 명세와 정확히 일치해야 한다(시드 고정 몬테카를로라 실행마다 동일).
숫자가 바뀌면 회귀로 잡힌다. = '재무 로직의 정확도 평가'.
"""
from __future__ import annotations

from ..data import PROFILE
from ..engine import build_plan

CASES = [
    # (방향, 후보반영, 기대 사용가능액, 기대 확률)
    ("reduce", False, 47_720, 88),
    ("maintain", False, 62_000, 81),
    ("increase", False, 80_360, 74),
    ("maintain", True, 62_000, 81),  # 미확정 후보가 없어 결과가 같아야 함
]


def run_golden() -> tuple[int, int, list[str]]:
    passed = 0
    details: list[str] = []
    for direction, include, exp_avail, exp_prob in CASES:
        p = PROFILE.model_copy(update={"direction": direction})
        r = build_plan(p, today=22, include_candidate=include)
        ok = r.weekly_available == exp_avail and r.probability == exp_prob
        passed += int(ok)
        tag = f"{direction}{'+후보' if include else ''}"
        details.append(
            f"[{'OK' if ok else 'FAIL'}] {tag}: "
            f"가용 {r.weekly_available:,}(기대 {exp_avail:,}) · "
            f"확률 {r.probability}%(기대 {exp_prob}%)"
        )
    return passed, len(CASES), details
