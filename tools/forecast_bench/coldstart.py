"""주차별 성능 곡선 — "쓸수록 개인 분포로 갱신되는가" 를 검증한다.

앱의 주장은 정확도가 높다는 게 아니다. **처음엔 인구 평균이고, 쓰다 보면 내 분포가
된다** 는 것이다. 그걸 재려면 성능을 한 숫자로 내면 안 되고 **주차별 곡선**이어야 한다.

세 갈래를 같은 데이터에 돌린다. 차이는 사전분포를 어떻게 쓰는가 하나뿐이다.

    prior      사전분포 고정. 관측을 절대 흡수하지 않는다 — 공개 통계만 쓰는 앱의 성능
    personal   사전분포 없이 개인 관측만. 관측이 없으면 예측하지 못한다(0원)
    hier       켤레 갱신. 인구에서 시작해 개인으로 옮겨간다 — 우리 것

`personal` 이 있어야 "그냥 개인 데이터 쓰면 되는데 왜 사전분포냐" 에 답할 수 있다.
초반에 무엇이 붕괴하는지 보여주는 게 그 갈래의 역할이다.

측정 세 개. 정확도만 보면 과신을 놓친다 — 구간을 좁히면서 커버리지가 무너지면
숫자는 좋아지고 앱은 거짓말쟁이가 된다.

    주간 총액 WAPE       앱 주지표. "이번 주 예상 지출" 의 오차
    80% 구간 커버리지    정직성. 80% 구간이 실제로 80% 를 덮는가
    구간폭 / 중앙값      확신. 사용자가 화면에서 폭으로 느끼는 것

    python coldstart.py
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

import mpp
from generate_synthetic import HABIT_POOL, N_WEEKS
from next_week import category_prior

HERE = Path(__file__).parent
Z80 = 1.2816                 # 80% 구간의 정규 분위
ARMS = ("prior", "personal", "hier")

# 인구 금액 사전분포. **생성기의 인구 중앙값을 그대로 쓴다.**
#
# 공개 통계값(baseline_prices.json)을 쓰면 사전분포가 인구 중심에서도 틀리게 되고,
# 그러면 prior 갈래가 부당하게 나빠져 개선폭이 부풀려진다. 여기서는 "사전분포가
# 인구 평균만은 정확히 안다" 는 가장 불리한 가정을 택했다 — 남는 오차는 전부
# 개인 편차뿐이고, 그게 개인화가 실제로 고치는 것이다.
# 따라서 이 실험의 개선폭은 **하한**이다.
POP_AMOUNT = {cat: mu for cat, _kind, mu, _sd, _prob in HABIT_POOL}


# 사전분포 무게(일). 아래 스윕에서 고른 값이다 — 5 일이면 1주차 예측력을 유지하면서
# 26주차 손실이 0.3% 로 사라진다. 30 일에서는 7.3% 를 계속 지불한다.
#
# **앱은 아직 30 을 쓴다** (`SpendPrior.init` 의 `strength: Double = 30`).
# 이 곡선을 실물로 만들려면 그 기본값을 5 로 내려야 한다.
STRENGTH = 5.0


def prior_for(category: str, arm: str, strength: float = STRENGTH) -> mpp.Prior:
    """카테고리 사전분포. `personal` 갈래는 무게를 0 으로 만든다.

    `strength` 는 사전분포를 관측 며칠 상당으로 믿는가다. 발생률 사후가
    `(a + n) / (b + days)` 이므로 `b = strength` 가 관측과 경쟁하는 무게다.
    이 값이 크면 콜드스타트가 안전해지고 개인화가 늦어진다 — 곡선의 양쪽 끝이
    이 하나의 숫자에 매달려 있어서 스윕한다.
    """
    gap, shape, sigma2 = category_prior(category)
    mu0 = float(np.log(POP_AMOUNT.get(category, 20_000)))
    if arm == "personal":
        # a,b → 0 이면 사후 발생률이 표본율 n/days 로, tau2 → ∞ 면 사후 금액이
        # 표본 평균으로 떨어진다. 즉 사전분포가 사라진다.
        return mpp.Prior(a=1e-9, b=1e-9, mu0=mu0, tau2=1e9,
                         sigma2=sigma2, gap_shape=shape)
    return mpp.Prior(a=strength / gap, b=strength, mu0=mu0, tau2=0.35,
                     sigma2=sigma2, gap_shape=shape)


def predict(tracker: mpp.Tracker, p: mpp.Prior, arm: str) -> tuple[float, float, float]:
    """다음 7일의 (총액, 건당금액 구간 하한, 상한).

    총액은 기대 건수 × 건당금액 중앙값이다. 앱의 `plannedSpendTotal` 이
    일정 금액(중앙값)의 합이므로 같은 양을 재려면 중앙값을 써야 한다.
    """
    c = tracker.slow
    if arm == "personal" and c.n_amt == 0:
        return 0.0, 0.0, 0.0          # 관측이 없으면 예측할 근거가 없다
    mu, sd = mpp.posterior_log_amount(c, p)
    per_tx = float(np.exp(mu))
    total = mpp.posterior_rate(c, p) * 7 * per_tx
    return total, float(np.exp(mu - Z80 * sd)), float(np.exp(mu + Z80 * sd))


def absorb(tracker: mpp.Tracker, p: mpp.Prior, week: int,
           days: dict[int, tuple[int, float]], state: dict) -> None:
    """그 주 관측을 카운터에 넣는다. 하루 단위로, 실제 간격만 gaps 로 넘긴다.

    `accounted` 는 카운터에 반영된 마지막 날, `last_tx` 는 실제 마지막 발생일이다.
    둘을 따로 든다 — 공백을 메우려고 accounted 를 주말로 밀면 다음 주 간격이
    발생일 사이 간격이 아니라 주말부터의 거리가 되어 규칙성 추정이 망가진다.
    """
    for d in sorted(days):
        count, amount = days[d]
        span = d - state["accounted"]
        gaps = [float(d - state["last_tx"])] if state["last_tx"] is not None else []
        tracker.update(count, amount, max(float(span), 1e-9), p=p, gaps=gaps)
        state["accounted"] = d
        state["last_tx"] = d

    week_end = week * 7 + 6
    if state["accounted"] < week_end:
        tracker.update(0, 0.0, float(week_end - state["accounted"]), p=p)
        state["accounted"] = week_end


def run(tx: pd.DataFrame, strength: float = STRENGTH) -> pd.DataFrame:
    """사람 × 주 × 갈래로 예측하고 실제와 비교한다. 그 주 데이터는 예측 후에 흡수한다."""
    rows = []

    for person, ph in tx.groupby("person", sort=True):
        # 예측 대상 카테고리는 고정한다. 앱은 캘린더와 온보딩에서 "이 사람이 카페를
        # 간다" 는 것까지는 안다 — 모르는 건 얼마나 자주 얼마씩인지다.
        cats = sorted(ph.category.unique())

        # (주, 카테고리) → {날짜: (건수, 금액합)} 으로 한 번만 접는다
        by_week: dict = {}
        for w, cat, d, amt in zip(ph.week, ph.category, ph.day, ph.amount):
            slot = by_week.setdefault((int(w), cat), {})
            n, s = slot.get(int(d), (0, 0.0))
            slot[int(d)] = (n + 1, s + float(amt))

        actual_week = ph.groupby("week").amount.sum().to_dict()
        priors = {(cat, arm): prior_for(cat, arm, strength)
                  for cat in cats for arm in ARMS}
        track = {(cat, arm): mpp.Tracker() for cat in cats for arm in ARMS}
        cursor = {(cat, arm): {"accounted": -1, "last_tx": None}
                  for cat in cats for arm in ARMS}

        for w in range(N_WEEKS):
            for arm in ARMS:
                total = 0.0
                covered = miss = 0
                width_ratio = []
                for cat in cats:
                    p = priors[(cat, arm)]
                    t, lo, hi = predict(track[(cat, arm)], p, arm)
                    total += t
                    if hi > lo > 0:
                        # lo·hi 의 기하평균이 곧 중앙값 exp(mu) 다 (구간이 로그 대칭)
                        width_ratio.append((hi - lo) / (lo * hi) ** 0.5)
                    # 그 주 실제 거래가 구간에 들어갔는지 (건당 금액 기준)
                    for _d, (n, s) in by_week.get((w, cat), {}).items():
                        per_tx = s / n
                        if lo <= 0 and hi <= 0:
                            miss += 1                    # 예측 자체가 없었다
                        elif lo <= per_tx <= hi:
                            covered += 1
                        else:
                            miss += 1

                rows.append({
                    "week": w + 1, "person": int(person), "arm": arm,
                    "pred": total, "actual": float(actual_week.get(w, 0.0)),
                    "covered": covered, "miss": miss,
                    "width": float(np.mean(width_ratio)) if width_ratio else np.nan,
                })

            # 예측이 끝난 뒤에 흡수한다. prior 갈래는 흡수하지 않는다 — 그게 정의다.
            for arm in ("personal", "hier"):
                for cat in cats:
                    days = by_week.get((w, cat))
                    absorb(track[(cat, arm)], priors[(cat, arm)], w,
                           days or {}, cursor[(cat, arm)])

    return pd.DataFrame(rows)


def curve(ev: pd.DataFrame) -> pd.DataFrame:
    """주차별 지표. WAPE 는 사람을 합쳐서 낸다 — 1인 1주는 표본이 너무 작다."""
    g = ev.groupby(["arm", "week"])
    out = pd.DataFrame({
        "wape": g.apply(lambda d: (d.pred - d.actual).abs().sum() / max(d.actual.sum(), 1),
                        include_groups=False),
        "coverage": g.apply(lambda d: d.covered.sum() / max(d.covered.sum() + d.miss.sum(), 1),
                            include_groups=False),
        "width": g.width.mean(),
    })
    return out.reset_index()


def main() -> None:
    tx = pd.read_parquet(HERE / "data/synthetic_tx.parquet")
    print(f"{tx.person.nunique()}명 × {N_WEEKS}주 · 거래 {len(tx):,}건\n")

    ev = run(tx)
    c = curve(ev)
    c.to_csv(HERE / "results/coldstart.csv", index=False)

    print("=== 주차별 주간 총액 오차 (WAPE · 낮을수록 좋음) ===")
    piv = c.pivot(index="week", columns="arm", values="wape")[list(ARMS)]
    print(f"  {'주차':>5} {'prior':>9} {'personal':>10} {'hier':>9}   {'hier 개선':>10}")
    print("  " + "-" * 52)
    for w in piv.index:
        r = piv.loc[w]
        gain = (r["prior"] - r["hier"]) / r["prior"] if r["prior"] > 0 else 0
        print(f"  {int(w):>5} {r['prior']:>9.3f} {r['personal']:>10.3f} "
              f"{r['hier']:>9.3f}   {gain:>+9.1%}")

    first, last = piv.index.min(), piv.index.max()
    a, b = piv.loc[first, "hier"], piv.loc[last, "hier"]
    print(f"\n  hier  {first}주차 {a:.3f} → {last}주차 {b:.3f}  "
          f"= 오차 {(a-b)/a:.1%} 감소")
    print(f"  prior {first}주차 {piv.loc[first,'prior']:.3f} → "
          f"{last}주차 {piv.loc[last,'prior']:.3f}  (고정이라 안 변한다)")

    print("\n=== 정직성과 확신 (hier) ===")
    h = c[c.arm == "hier"].set_index("week")
    print(f"  {'주차':>5} {'커버리지80':>11} {'구간폭/중앙':>12}")
    print("  " + "-" * 32)
    for w in h.index:
        print(f"  {int(w):>5} {h.loc[w,'coverage']:>10.1%} {h.loc[w,'width']:>11.2f}")

    print("\n  → 폭이 좁아지는데 커버리지가 80% 근처를 지키면 개인화가 정직하다.")
    print("     폭만 좁아지고 커버리지가 무너지면 과신이다.")

    # personal 이 hier 를 이기면 계층 구조가 정당화되지 않는다. 사전분포 무게가
    # 잘못 조정된 것인지(튜닝) 구조가 값어치 없는 것인지(부정적 결과) 가른다.
    print("\n=== 사전분포 무게 스윕 — 계층 구조가 값어치가 있는가 ===")
    print(f"  {'무게(일)':>9} {'1주차':>8} {'8주차':>8} {'26주차':>8}   {'26주차 personal 대비':>20}")
    print("  " + "-" * 62)
    ref = curve(ev)
    ref_personal = ref[(ref.arm == "personal")].set_index("week").wape
    for s in (5.0, 10.0, 30.0):
        cs = curve(run(tx, strength=s))
        h = cs[cs.arm == "hier"].set_index("week").wape
        vs = (ref_personal.loc[26] - h.loc[26]) / ref_personal.loc[26]
        print(f"  {s:>9.0f} {h.loc[1]:>8.3f} {h.loc[8]:>8.3f} {h.loc[26]:>8.3f}   "
              f"{vs:>+19.1%}")
    print(f"  {'(personal)':>9} {ref_personal.loc[1]:>8.3f} "
          f"{ref_personal.loc[8]:>8.3f} {ref_personal.loc[26]:>8.3f}")
    print("\n  1주차는 낮을수록, 26주차는 personal 에 붙을수록 좋다.")
    print("  둘을 동시에 만족하는 무게가 있으면 계층 구조가 이긴다.")


def _selfcheck() -> None:
    """구조적 불변식. 깨지면 갈래 정의가 새고 있다."""
    tx = pd.DataFrame([
        {"person": 0, "day": 3, "week": 0, "weekday": 3, "category": "카페",
         "kind": "irregular", "amount": 5000.0, "visible": True},
        {"person": 0, "day": 10, "week": 1, "weekday": 3, "category": "카페",
         "kind": "irregular", "amount": 5000.0, "visible": True},
    ])
    ev = run(tx)

    p = ev[ev.arm == "prior"].pred
    assert p.nunique() == 1, f"prior 갈래 예측이 변했다: {p.unique()}"

    w1 = ev[ev.week == 1].set_index("arm").pred
    assert abs(w1["hier"] - w1["prior"]) < 1e-6, \
        f"1주차에 hier != prior: {w1['hier']} vs {w1['prior']}"
    assert w1["personal"] == 0.0, f"1주차 personal 이 0 이 아니다: {w1['personal']}"

    w3 = ev[ev.week == 3].set_index("arm").pred
    assert w3["personal"] > 0, "관측 뒤에도 personal 이 예측하지 못한다"
    print("_selfcheck 통과 — prior 고정 · 1주차 hier=prior · personal 콜드스타트 0")


if __name__ == "__main__":
    _selfcheck()
    print()
    main()
