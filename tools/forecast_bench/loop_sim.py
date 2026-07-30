"""질문 루프 시뮬레이션 — "물어보면서 조정해나간다" 를 검증한다.

앞선 평가(methods.py)는 모델을 **수동**으로 봤다. 거래를 관측하고 예측만 했다.
실제 제품은 **묻고 답을 받는다.** 그리고 답변은 거래 로그에 없는 정보다:

    현금·계좌이체·더치페이·친구가 계산한 소비는 카드 명세에 안 남는다 (전체 15.3%,
    모임은 41%). 카드만 보면 그 습관이 영원히 약하게 보인다. 물어봐야 알 수 있다.

그래서 조건을 나눠 비교한다.

    passive   카드 명세만 본다. 질문은 하지만 답을 학습에 쓰지 않는다
    active    답변을 관측으로 흡수한다 — 안 보이던 소비가 보이기 시작한다

측정은 **주차별 정밀도 곡선**이다. "쓸수록 나아지는가" 가 이 제품의 주장이니까.

    python loop_sim.py
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).parent
WEEKDAY = ["월", "화", "수", "목", "금", "토", "일"]

LOOKBACK = 8
DECAY = 0.85
WARMUP = 8            # 이 주까지는 관측만 쌓고 질문하지 않는다
THRESHOLD = 0.45      # 이 확률을 넘을 때만 묻는다. 실제 질문 빈도는 측정한다


@dataclass
class Observed:
    """모델이 아는 것. 카드 명세 + 질문 답변.

    `card` 는 (주, 카테고리) → 발생 요일 집합. **미리 만들어 둔다** —
    내부 루프에서 pandas 를 필터하면 조건당 37만 번이 되어 시뮬레이션이 안 끝난다.
    """
    card: dict                                        # (week, cat) -> set[int]
    answers: dict = field(default_factory=dict)       # (week, cat, wd) -> bool

    def hits(self, cat: str, week: int) -> set[int]:
        """그 주에 그 카테고리가 발생한 요일. 답변이 있으면 답변이 이긴다."""
        seen = set(self.card.get((week, cat), ()))
        for d in range(7):
            ans = self.answers.get((week, cat, d))
            if ans is True:
                seen.add(d)
            elif ans is False:
                seen.discard(d)
        return seen


def score_m3(obs: Observed, cats: list[str], upto: int) -> pd.DataFrame:
    """methods.py 에서 이긴 M3. P(그 주 발생) × P(요일 | 발생)."""
    look = np.arange(max(0, upto - LOOKBACK), upto)
    if len(look) == 0:
        return pd.DataFrame()
    wt = DECAY ** (upto - 1 - look)
    wsum = wt.sum()

    rows = []
    for cat in cats:
        hits = np.zeros(7)
        any_week = 0.0
        for wi, week in enumerate(look):
            days = obs.hits(cat, int(week))
            if days:
                any_week += wt[wi]
            for d in days:
                hits[d] += wt[wi]
        rate = hits / wsum
        tot = rate.sum()
        share = rate / tot if tot > 0 else np.full(7, 1 / 7)
        p_week = any_week / wsum
        for d in range(7):
            rows.append({"category": cat, "weekday": d,
                         "p": float(p_week * share[d]),
                         "recent": int(sum(1 for w in range(max(0, upto - 3), upto)
                                           if d in obs.hits(cat, w)))})
    return pd.DataFrame(rows)


def run(tx_all: pd.DataFrame, mode: str, threshold: float = THRESHOLD,
        answer_reliability: float = 1.0, response_rate: float = 1.0,
        seed: int = 0) -> pd.DataFrame:
    """한 조건을 26주 돌린다.

    answer_reliability  "네" 라고 답했는데 실제로 안 하는 비율의 여집합
    response_rate       질문에 답하는 비율. 나머지는 무응답
    """
    rng = np.random.default_rng(seed)
    weeks = sorted(tx_all.week.unique())
    out = []

    for person, ph in tx_all.groupby("person"):
        # 카드 명세를 (주, 카테고리) → 요일 집합으로 한 번만 접는다
        card: dict = {}
        v = ph[ph.visible]
        for wk, c, d in zip(v.week, v.category, v.weekday):
            card.setdefault((int(wk), c), set()).add(int(d))
        # 정답도 미리 접는다 (평가용)
        truth_by_week: dict = {}
        for wk, c, d in zip(ph.week, ph.category, ph.weekday):
            truth_by_week.setdefault(int(wk), set()).add((c, int(d)))

        obs = Observed(card=card)
        cats = sorted(ph.category.unique())

        for w in weeks:
            if w <= WARMUP:
                continue
            pred = score_m3(obs, cats, w)
            if pred.empty:
                continue

            # 임계값을 넘는 것만 묻는다. 안 넘으면 그 주는 묻지 않는다 —
            # 매주 억지로 하나씩 물어보면 확신 없는 질문이 섞여 정밀도가 떨어진다.
            asked = pred[pred.p >= threshold].nlargest(2, "p")
            if asked.empty:
                continue
            truth = truth_by_week.get(int(w), set())

            for _, r in asked.iterrows():
                actually = (r.category, int(r.weekday)) in truth
                out.append({"person": person, "week": int(w), "mode": mode,
                            "category": r.category, "weekday": int(r.weekday),
                            "p": r.p, "correct": actually})

                if mode == "active":
                    if rng.random() > response_rate:
                        continue                        # 무응답
                    said = actually
                    if rng.random() > answer_reliability:
                        said = not actually             # 답변이 틀렸다
                    obs.answers[(int(w), r.category, int(r.weekday))] = said
    return pd.DataFrame(out)


def curve(df: pd.DataFrame, bucket: int = 3) -> pd.Series:
    """주차를 묶어 정밀도 추이를 본다. 주별로는 표본이 적어 흔들린다."""
    b = ((df.week - WARMUP - 1) // bucket) * bucket + WARMUP + 1
    return df.groupby(b).correct.agg(["mean", "size"])


def main() -> None:
    tx = pd.read_parquet(HERE / "data/synthetic_tx.parquet")
    print(f"{tx.person.nunique()}명 · {tx.week.max()+1}주 · "
          f"카드 명세에 안 남는 소비 {1-tx.visible.mean():.1%}\n")

    print("=== 실험 A · 답변을 학습하면 나아지는가 ===")
    passive = run(tx, "passive", seed=1)
    active = run(tx, "active", seed=1)
    print(f"  passive  질문 {len(passive):,}건 · 정밀도 {passive.correct.mean():.1%}")
    print(f"  active   질문 {len(active):,}건 · 정밀도 {active.correct.mean():.1%}")
    diff = active.correct.mean() - passive.correct.mean()
    print(f"  차이     {diff:+.1%}p\n")

    print("  주차별 추이 (3주 묶음)")
    cp, ca = curve(passive), curve(active)
    print(f"  {'주차':>8} {'passive':>9} {'active':>9} {'차이':>8}")
    for wk in cp.index:
        if wk not in ca.index:
            continue
        print(f"  {int(wk):>5}~{int(wk)+2:<3} {cp.loc[wk,'mean']:>8.1%} "
              f"{ca.loc[wk,'mean']:>8.1%} {ca.loc[wk,'mean']-cp.loc[wk,'mean']:>+7.1%}p")

    print("\n=== 실험 B · 임계값을 낮춰 많이 물어보면 ===")
    n_pw = tx.person.nunique() * (int(tx.week.max()) - WARMUP)
    print(f"  {'임계값':>8} {'질문/주·명':>10} {'정밀도':>8} {'후반 정밀도':>11}")
    for th in [0.3, 0.45, 0.6, 0.75]:
        r = run(tx, "active", threshold=th, seed=2)
        late = r[r.week >= tx.week.max() - 5]
        print(f"  {th:>8.2f} {len(r)/n_pw:>10.2f} {r.correct.mean():>7.1%} "
              f"{late.correct.mean():>10.1%}")

    print("\n=== 실험 C · 답변이 틀리거나 무응답이면 견디는가 ===")
    print(f"  {'조건':>22} {'정밀도':>8}")
    for label, rel, resp in [("완벽한 답변", 1.0, 1.0),
                             ("답변 신뢰 90%", 0.9, 1.0),
                             ("답변 신뢰 70%", 0.7, 1.0),
                             ("무응답 50%", 1.0, 0.5),
                             ("신뢰 80% + 무응답 50%", 0.8, 0.5)]:
        r = run(tx, "active", answer_reliability=rel, response_rate=resp, seed=3)
        print(f"  {label:>22} {r.correct.mean():>7.1%}")

    print("\n=== 실험 D · 안 보이는 소비가 많은 카테고리에서 이득이 큰가 ===")
    inv = tx.groupby("category").visible.mean().rsub(1)
    g = (active.groupby("category").correct.mean()
         - passive.groupby("category").correct.mean())
    n = active.groupby("category").size()
    tbl = pd.DataFrame({"안보임": inv, "질문수": n, "active−passive": g}).dropna()
    tbl = tbl[tbl.질문수 >= 50].sort_values("안보임", ascending=False)
    tbl["안보임"] = tbl["안보임"].map("{:.0%}".format)
    tbl["active−passive"] = tbl["active−passive"].map("{:+.1%}".format)
    print(tbl.to_string())


if __name__ == "__main__":
    main()
