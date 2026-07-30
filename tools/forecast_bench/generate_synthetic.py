"""소비자별 합성 거래 데이터. AI Hub 가 못 준 두 가지를 만든다 — **거래 단위**와 **주간 축**.

AI Hub 117 은 회원×월 집계라 거래 하나하나가 없고, 그래서 주간 예상 지출·발생 확률·
요일 패턴을 평가할 수 없었다(METHOD.md §2.3). 여기서 그걸 만든다.

사람마다 습관 구성이 다르고, 습관마다 구조가 다르다:

    weekday    매주 토요일 저녁 — 요일이 앵커다. 간격 모델로는 안 잡힌다
    interval   10일마다 장보기 — 간격이 앵커
    fixed      매월 5일 구독료 — 날짜·금액 모두 고정
    irregular  카페 — 아무 때나 (무기억)

일부 습관은 중간에 시작하거나 끝난다. 습관 변화 감지를 평가하려면 그게 있어야 한다.

    python generate_synthetic.py   → data/synthetic_tx.parquet
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).parent
OUT = HERE / "data"

N_PEOPLE = 300
N_WEEKS = 26
SEED = 20260730

# 거래 로그에 안 남는 소비 비율. 현금·계좌이체·더치페이·친구가 계산.
# **이게 질문이 존재하는 이유다.** 카드 명세만 보면 이 소비는 영원히 안 보이고,
# 요일 프로파일이 그만큼 약해진다. 물어봐야만 알 수 있다.
INVISIBLE_RATE = {
    "모임": 0.40,      # 더치페이·번갈아 계산이 흔하다
    "데이트": 0.30,
    "외식": 0.25,
    "카페": 0.15,
    "생활": 0.05,      # 장보기는 대체로 카드
    "교통": 0.05,
    "쇼핑": 0.10,
    "자기관리": 0.10,
    "구독": 0.00,      # 자동결제라 항상 남는다
}


@dataclass
class Habit:
    category: str
    kind: str                      # weekday | interval | fixed | irregular
    amount_mu: float               # 건당 금액 중앙값
    amount_log_sd: float           # 금액 변동 (로그 스케일)
    weekday: int | None = None     # 0=월 … 5=토 6=일
    interval_days: float | None = None
    day_of_month: int | None = None
    per_week: float | None = None  # irregular 의 주당 건수
    start_week: int = 0
    end_week: int | None = None    # None = 끝까지

    def active(self, week: int) -> bool:
        return week >= self.start_week and (self.end_week is None or week < self.end_week)


# 인구에서 습관을 뽑는 사전분포. 카테고리마다 구조가 다르다.
HABIT_POOL = [
    # (카테고리, 구조, 금액중앙값, 금액변동, 보유확률)
    ("모임",     "weekday",   45_000, 0.30, 0.55),   # 매주 같은 요일 저녁 약속
    ("데이트",   "weekday",   70_000, 0.25, 0.35),
    ("생활",     "interval",  35_000, 0.15, 0.80),   # 장보기
    ("자기관리", "interval",  30_000, 0.10, 0.60),   # 미용실
    ("구독",     "fixed",      9_900, 0.00, 0.70),   # 금액 완전 고정
    ("카페",     "irregular",  5_500, 0.45, 0.90),
    ("외식",     "irregular", 16_000, 0.40, 0.85),
    ("쇼핑",     "irregular", 60_000, 0.70, 0.65),   # 변동 가장 큼
    ("교통",     "irregular",  2_800, 0.30, 0.75),
]


def make_person(rng: np.random.Generator) -> list[Habit]:
    """사람 한 명의 습관 구성. 보유 여부·주기·금액이 사람마다 다르다."""
    habits = []
    for cat, kind, mu, sd, prob in HABIT_POOL:
        if rng.random() > prob:
            continue
        # 개인 금액은 인구 중앙값 주변에서 뽑는다 (개인 간 분산)
        personal_mu = mu * float(np.exp(rng.normal(0, 0.35)))

        h = Habit(category=cat, kind=kind, amount_mu=personal_mu, amount_log_sd=sd)
        if kind == "weekday":
            h.weekday = int(rng.integers(0, 7))
            # 매주는 아니고 대체로 매주 — 이게 감지 난이도를 만든다
            h.per_week = float(rng.uniform(0.6, 1.0))
        elif kind == "interval":
            base = 10.0 if cat == "생활" else 42.0
            h.interval_days = float(base * rng.uniform(0.7, 1.4))
        elif kind == "fixed":
            h.day_of_month = int(rng.integers(1, 29))
        else:
            h.per_week = float(rng.gamma(2.0, 1.2))     # 주당 건수, 사람마다 크게 다름

        # 20% 는 중간에 시작하거나 끊는다 — 습관 변화 평가용
        r = rng.random()
        if r < 0.10:
            h.start_week = int(rng.integers(6, 16))
        elif r < 0.20:
            h.end_week = int(rng.integers(10, 22))
        habits.append(h)
    return habits


def emit(person: int, habits: list[Habit], rng: np.random.Generator) -> list[dict]:
    rows = []
    for h in habits:
        for w in range(N_WEEKS):
            if not h.active(w):
                continue
            week_start = w * 7

            if h.kind == "weekday":
                if rng.random() > h.per_week:
                    continue                       # 그 주는 건너뛴다
                # 요일이 앵커지만 10% 는 하루 밀린다
                shift = int(rng.choice([0, 0, 0, 0, 0, 0, 0, 0, 0, 1, -1]))
                day = week_start + h.weekday + shift
                days = [day] if 0 <= day < N_WEEKS * 7 else []

            elif h.kind == "interval":
                # 이 주 안에 발생일이 걸리는지 갱신과정으로 판정
                lam = 7.0 / h.interval_days
                n = rng.poisson(lam)
                days = [week_start + int(rng.integers(0, 7)) for _ in range(n)]

            elif h.kind == "fixed":
                # 매월 같은 날. 주 단위 루프라 그 주에 해당 날짜가 있는지 본다
                days = [week_start + d for d in range(7)
                        if (week_start + d) % 30 + 1 == h.day_of_month]

            else:  # irregular
                n = rng.poisson(h.per_week)
                days = [week_start + int(rng.integers(0, 7)) for _ in range(n)]

            for d in days:
                if d >= N_WEEKS * 7:
                    continue
                amt = h.amount_mu if h.amount_log_sd == 0 else \
                    float(np.exp(rng.normal(np.log(h.amount_mu), h.amount_log_sd)))
                rows.append({
                    "person": person, "day": int(d), "week": d // 7,
                    "weekday": int(d % 7), "category": h.category,
                    "kind": h.kind, "amount": round(amt, -2),
                    # 거래 로그에 남는가. 안 남으면 질문으로만 알 수 있다.
                    "visible": bool(rng.random() >= INVISIBLE_RATE.get(h.category, 0.1)),
                })
    return rows


def main() -> None:
    OUT.mkdir(exist_ok=True)
    rng = np.random.default_rng(SEED)

    rows, truth = [], []
    for p in range(N_PEOPLE):
        habits = make_person(rng)
        rows += emit(p, habits, rng)
        for h in habits:
            truth.append({"person": p, "category": h.category, "kind": h.kind,
                          "weekday": h.weekday, "interval_days": h.interval_days,
                          "amount_mu": h.amount_mu, "per_week": h.per_week,
                          "start_week": h.start_week, "end_week": h.end_week})

    tx = pd.DataFrame(rows).sort_values(["person", "day"]).reset_index(drop=True)
    gt = pd.DataFrame(truth)
    tx.to_parquet(OUT / "synthetic_tx.parquet", index=False)
    gt.to_parquet(OUT / "synthetic_truth.parquet", index=False)

    print(f"{OUT/'synthetic_tx.parquet'}  {len(tx):,} 거래 · {tx.person.nunique()} 명 · {N_WEEKS} 주")
    print(f"{OUT/'synthetic_truth.parquet'}  {len(gt):,} 습관 (정답)")
    print()
    print("=== 구조별 ===")
    s = gt.groupby("kind").agg(습관수=("person", "size"), 보유자=("person", "nunique"))
    s["거래수"] = tx.groupby("kind").size()
    print(s.to_string())
    print()
    print("=== 사람당 ===")
    print(f"  습관 {gt.groupby('person').size().median():.0f}개 (중앙값) · "
          f"거래 {tx.groupby('person').size().median():.0f}건 · "
          f"주당 {tx.groupby('person').size().median() / N_WEEKS:.1f}건")
    print(f"  중간에 시작한 습관 {(gt.start_week > 0).sum()}개 · "
          f"중간에 끊은 습관 {gt.end_week.notna().sum()}개")
    print()
    print("=== 거래 로그에 안 남는 소비 (질문으로만 알 수 있는 것) ===")
    inv = tx.groupby("category").visible.agg(["size", "mean"])
    inv["안보임"] = (1 - inv["mean"]).map("{:.0%}".format)
    print(inv[["size", "안보임"]].rename(columns={"size": "거래수"}).to_string())
    print(f"  전체 {1 - tx.visible.mean():.1%} 가 카드 명세에 안 남는다")
    print()
    print("=== 요일 패턴이 실제로 요일에 몰리는가 (weekday 구조만) ===")
    wd = tx[tx.kind == "weekday"]
    hit = (wd.weekday == wd.merge(gt[gt.kind == "weekday"], on=["person", "category"],
                                  how="left")["weekday_y"].values).mean()
    print(f"  정답 요일에 발생한 비율 {hit:.1%}  (10% 는 의도적으로 하루 밀림)")


if __name__ == "__main__":
    main()
