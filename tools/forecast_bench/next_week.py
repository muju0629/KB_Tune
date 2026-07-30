"""다음 주 1주치를 예측한다. 주간 브리핑이 물어볼 것을 만드는 로직.

    "토요일에 약속 생기시나요? 최근 3주 토요일마다 저녁 약속이 있었어요.
     예상 금액은 45,000원 정도예요."

평가는 금액 정확도가 아니라 **질문이 맞았는가**로 한다.

    제안했는데 실제로 발생   → 맞은 질문  (TP)
    제안했는데 미발생        → 헛질문     (FP)  ← 사용자가 짜증내는 쪽
    제안 안 했는데 발생      → 놓친 기회  (FN)

임계값을 올리면 헛질문이 줄고 놓치는 게 늘어난다. **이 표로 임계값을 정한다.**

    python next_week.py
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

import mpp

HERE = Path(__file__).parent
WEEKDAY = ["월", "화", "수", "목", "금", "토", "일"]

LOOKBACK = 8          # 요일 패턴을 볼 주 수
DECAY = 0.85          # 최근 주에 더 무게 — 습관이 바뀌면 따라가야 한다
FIRST_TEST_WEEK = 12  # 이 주부터 예측을 평가한다 (앞은 학습 기간)

# 요일 집중도가 이 이상이면 "요일 습관" 으로 본다.
# 매주 토요일 같은 패턴은 요일이 앵커라서 간격 모델로는 안 잡힌다.
WEEKDAY_CONCENTRATION = 0.45


def weekday_rates(hist: pd.DataFrame, upto_week: int) -> np.ndarray:
    """(카테고리 × 요일) 발생률. 최근 주에 가중을 준다.

    반환값은 "그 요일에 최소 1건 발생할 확률" 의 추정치다.
    """
    weeks = np.arange(max(0, upto_week - LOOKBACK), upto_week)
    if len(weeks) == 0:
        return np.zeros((0, 7))
    w = DECAY ** (upto_week - 1 - weeks)          # 최근 주가 큰 가중
    total = w.sum()

    cats = sorted(hist.category.unique())
    out = np.zeros((len(cats), 7))
    for ci, cat in enumerate(cats):
        sub = hist[hist.category == cat]
        for wi, week in enumerate(weeks):
            days = sub[sub.week == week].weekday.unique()
            for d in days:
                out[ci, d] += w[wi]
    return out / total


def concentration(rates_row: np.ndarray) -> float:
    """요일 편중도. 한 요일에 몰려 있으면 1 에 가깝고 고르면 1/7 에 가깝다."""
    s = rates_row.sum()
    return float(rates_row.max() / s) if s > 0 else 0.0


def predict_week(hist: pd.DataFrame, upto_week: int) -> pd.DataFrame:
    """`upto_week` 주를 예측한다. 그 이전 데이터만 쓴다 (누출 없음)."""
    hist = hist[hist.week < upto_week]
    if hist.empty:
        return pd.DataFrame()

    cats = sorted(hist.category.unique())
    rates = weekday_rates(hist, upto_week)
    rows = []

    for ci, cat in enumerate(cats):
        sub = hist[hist.category == cat]
        conc = concentration(rates[ci])

        # 금액 사후분포 — 카테고리 사전분포 + 개인 관측
        gap, shape, sigma2 = category_prior(cat)
        prior = mpp.Prior(a=30 / gap, b=30, mu0=np.log(max(sub.amount.median(), 1)),
                          tau2=0.35, sigma2=sigma2, gap_shape=shape)
        c = mpp.Counters()
        days = sorted(sub.day.unique())
        prev = days[0]
        for i, d in enumerate(days):
            amt = float(sub[sub.day == d].amount.sum())
            n = int((sub.day == d).sum())
            span = 1.0 if i == 0 else float(d - prev)
            c.update(n, amt, span, decay=0.95, gaps=[] if i == 0 else [float(d - prev)])
            prev = d
        idle = float(upto_week * 7 - prev)
        if idle > 0:
            c.update(0, 0, idle, decay=0.95)

        mu, sd = mpp.posterior_log_amount(c, prior)
        amount = float(np.exp(mu))
        low, high = float(np.exp(mu - 1.2816 * sd)), float(np.exp(mu + 1.2816 * sd))

        # 주 전체 발생 확률 — 요일 신호가 약한 카테고리는 빈도로 판단한다
        week_p = mpp.prob_within(c, mpp.Prior(**{**prior.__dict__,
                                                "gap_shape": mpp.estimate_shape(c, prior)}),
                                 7, elapsed=c.last_gap)

        # 질문 단위가 두 종류다. 하나의 격자에 억지로 넣으면 한쪽이 죽는다 —
        # 주 확률을 7 로 나누면 최대 0.14 라 임계값을 구조적으로 못 넘는다.
        #
        #   요일 질문   "토요일에 약속 생기시나요?"      요일이 앵커인 습관
        #   주간 질문   "이번 주 카페에 2만원 쓰실 듯"   요일을 모르는 습관
        #
        # 카페는 요일을 지정할 필요가 없다. 주 단위로 금액만 말하면 된다.
        if conc >= WEEKDAY_CONCENTRATION:
            for d in range(7):
                rows.append({"category": cat, "kind": "요일", "weekday": d,
                             "p": float(rates[ci, d]), "concentration": conc,
                             "amount": amount, "low": low, "high": high,
                             "recent_weeks": recent_weekday_hits(sub, upto_week, d)})
        else:
            per_week = mpp.posterior_rate(c, prior) * 7      # 주당 기대 건수
            rows.append({"category": cat, "kind": "주간", "weekday": -1,
                         "p": float(week_p), "concentration": conc,
                         "amount": amount * per_week,
                         "low": low * per_week, "high": high * per_week,
                         "recent_weeks": 0})
    return pd.DataFrame(rows)


def recent_weekday_hits(sub: pd.DataFrame, upto_week: int, weekday: int) -> int:
    """최근 3주 중 그 요일에 발생한 주 수. 브리핑 문장의 근거로 쓴다."""
    weeks = range(max(0, upto_week - 3), upto_week)
    return sum(1 for w in weeks
               if ((sub.week == w) & (sub.weekday == weekday)).any())


def category_prior(cat: str) -> tuple[float, float, float]:
    """SpendPriors.cadence 의 파이썬 사본. (평균주기, 규칙성, 금액변동)"""
    return {
        "구독": (30, 4.0, 0.01), "자기관리": (42, 3.0, 0.02), "교통": (2, 2.4, 0.05),
        "생활": (10, 2.4, 0.06), "데이트": (14, 2.0, 0.12), "모임": (14, 1.4, 0.18),
        "외식": (5, 1.0, 0.20), "카페": (3, 1.0, 0.25), "쇼핑": (12, 1.1, 0.45),
    }.get(cat, (14, 1.0, 0.16))


def briefing(pred: pd.DataFrame, threshold: float) -> list[str]:
    """임계값을 넘은 셀을 사람 말로. 주간 화면에 띄울 질문."""
    hits = pred[pred.p >= threshold].sort_values("p", ascending=False)
    out = []
    for _, r in hits.iterrows():
        if r.kind == "요일" and r.recent_weeks >= 2:
            out.append(f"{WEEKDAY[int(r.weekday)]}요일에 {r.category} 약속 생기시나요? "
                       f"최근 3주 중 {int(r.recent_weeks)}주는 {WEEKDAY[int(r.weekday)]}요일에 있었어요. "
                       f"예상 금액은 {r.amount:,.0f}원 정도예요.")
        else:
            out.append(f"{r.category}에 {r.amount:,.0f}원 정도 쓰실 것 같아요 "
                       f"({r.low:,.0f}~{r.high:,.0f}원).")
    return out


def main() -> None:
    tx = pd.read_parquet(HERE / "data/synthetic_tx.parquet")
    people = sorted(tx.person.unique())
    weeks = range(FIRST_TEST_WEEK, int(tx.week.max()) + 1)

    records = []
    for p in people:
        h = tx[tx.person == p]
        for w in weeks:
            pred = predict_week(h, w)
            if pred.empty:
                continue
            actual = h[h.week == w]
            hit = set(zip(actual.category, actual.weekday))
            for _, r in pred.iterrows():
                if r.kind == "요일":
                    occurred = (r.category, r.weekday) in hit
                    act = float(actual[(actual.category == r.category) &
                                       (actual.weekday == r.weekday)].amount.sum())
                else:
                    occurred = bool((actual.category == r.category).any())
                    act = float(actual[actual.category == r.category].amount.sum())
                records.append({
                    "person": p, "week": w, "category": r.category,
                    "weekday": r.weekday, "p": r.p, "kind": r.kind,
                    "occurred": occurred, "pred_amount": r.amount,
                    "actual_amount": act,
                })
    ev = pd.DataFrame(records)
    ev.to_parquet(HERE / "data/next_week_eval.parquet", index=False)

    n_pw = len(people) * len(list(weeks))
    print(f"평가 대상 {len(ev):,} 건 · {len(people)}명 × {len(list(weeks))}주\n")

    for kind, label in [("요일", '요일 질문 — "토요일에 약속 생기시나요?"'),
                        ("주간", '주간 질문 — "이번 주 카페에 X원 쓰실 것 같아요"')]:
        k = ev[ev.kind == kind]
        if k.empty:
            continue
        print(f"=== {label} ===")
        print(f"  대상 {len(k):,}건 · 실제 발생률 {k.occurred.mean():.1%}")
        print(f"  {'임계값':>6} {'질문/주·명':>10} {'맞음':>7} {'헛질문':>7} "
              f"{'정밀도':>7} {'재현율':>7}")
        print("  " + "-" * 52)
        for th in [0.3, 0.4, 0.5, 0.6, 0.7, 0.8]:
            asked = k[k.p >= th]
            tp = int(asked.occurred.sum())
            fp = len(asked) - tp
            fn = int(k[(k.p < th) & k.occurred].shape[0])
            prec = tp / len(asked) if len(asked) else float("nan")
            rec = tp / (tp + fn) if (tp + fn) else float("nan")
            print(f"  {th:>6.1f} {len(asked)/n_pw:>10.2f} {tp:>7,} {fp:>7,} "
                  f"{prec:>6.1%} {rec:>6.1%}")
        occ = k[k.occurred & (k.actual_amount > 0)]
        if len(occ):
            err = (occ.pred_amount - occ.actual_amount).abs().sum() / occ.actual_amount.sum()
            print(f"  금액 WAPE {err:.1%}  (실제 발생한 건만, n={len(occ):,})")
        print()

    print("=== 브리핑 예시 — 요일 질문이 뜬 사람들 ===")
    shown = 0
    last = int(tx.week.max())
    for p in people:
        pred = predict_week(tx[tx.person == p], last)
        if pred.empty:
            continue
        lines = [l for l in briefing(pred, 0.6) if "생기시나요" in l]
        if not lines:
            continue
        print(f"\n  [{p}번 사용자]")
        for l in lines[:2]:
            print(f"   · {l}")
        for l in briefing(pred, 0.6):
            if "생기시나요" not in l:
                print(f"   · {l}")
                break
        shown += 1
        if shown >= 3:
            break


if __name__ == "__main__":
    main()
