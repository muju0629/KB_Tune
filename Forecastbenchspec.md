# 소비 예측 모델 벤치마크 — 작업 지시서

> KB Tune의 금액 추정을 "과거 중앙값 + 규칙"에서 검증된 예측 모델로 올리는 작업.
> 목표는 **가장 정확한 모델을 찾는 것이 아니라, 온디바이스에서 돌릴 수 있는 최선을 찾고 그것이 현재 방식보다 나은지 숫자로 증명하는 것**이다.

---

## 0. 먼저 읽을 것

작업 시작 전 다음 파일을 읽고 현재 추정 로직을 정확히 파악한다.

- `backend/app/engine/estimate.py` — 일정 → 예상 금액
- `backend/app/engine/forecast.py` — 다음 달 예측
- `backend/app/engine/probability.py` — **목표 달성 확률. σ=100,000 하드코딩이 있다. 이걸 대체하는 게 이 작업의 핵심 성과 중 하나다.**
- `backend/app/baseline.py`, `backend/data/baseline_prices.json` — 공표 통계 기준 금액
- `KB_Tune/SpendHistory.swift`, `KB_Tune/EventEstimator.swift`, `KB_Tune/BudgetEngine.swift` — 온디바이스 구현. 최종 승자는 여기에 이식 가능해야 한다.

`README.md`의 "알고리즘" 절과 `docs/competition/FINAL_IMPLEMENTATION_EVIDENCE.md`의 서술 톤을 유지한다 — 과장하지 않고, 한계를 함께 적는다.

---

## 1. 예측 대상 정의 (여기서 틀리면 전부 무의미)

세 개를 구분해서 각각 평가한다. 섞지 말 것.

| ID | 대상 | 단위 | 앱에서 대응되는 화면 |
|---|---|---|---|
| **T1** | 주간 총 지출 | 사용자 × ISO주 | 주간 화면 "이번 주 예상 지출 130,000원" — **주지표** |
| **T2** | 일정 단건 금액 | 거래 1건 | 일정 추가 "예상 50,000원 · 범위 40,671~148,029원" |
| **T3** | 카테고리별 주간 지출 | 사용자 × 카테고리 × 주 | T1의 구성요소. Chronos-2 다변량이 유리한 지점 |

주지표는 **T1**이다. 화면의 큰 숫자와 추가 사용 가능액을 결정하기 때문이다.

---

## 2. 데이터

### 2-1. AI Hub 금융 합성 데이터 (주 데이터)

zip은 이미 로컬에 있다. **스키마를 추측하지 말고 반드시 먼저 조사한다.**

1. zip을 `data/aihub/` 에 풀고 **`.gitignore`에 추가한다.** 원본을 절대 커밋하지 않는다 (용량 + 재식별 위험).
2. 카드 승인매출정보 파일을 찾아 컬럼 목록·dtype·결측률·행 수를 `docs/aihub-schema-notes.md`에 기록한다. 컬럼이 430개라 이 문서 없이는 이후 작업이 불가능하다.
3. 이용약관을 확인하고 **공모전 산출물에 활용·공표가 가능한지, 출처 표기 의무가 있는지**를 같은 문서에 적는다. 불명확하면 그 사실을 적고 진행한다.
4. **먼저 5,000명 규모로 샘플링해서 파이프라인을 완성한다.** 1.6억 건을 처음부터 돌리지 않는다. 스케일업은 파이프라인이 검증된 뒤.

### 2-2. 정규화 계약 (canonical format)

모든 데이터 소스를 이 두 테이블로 변환한다. 이후 모든 코드는 이 스키마만 안다.

```
tx.parquet      user_id: str, ts: date, category: str, amount: float
weekly.parquet  user_id: str, week_start: date, category: str, amount_sum: float, tx_count: int
```

`weekly`는 **주별 결측을 0으로 채워 연속으로 만든다.** Chronos-2는 시계열에 간격(gap)이 있으면 안 된다 (`predict_df` 문서 명시).

### 2-3. 합성 데이터 생성기 (보조 — 캘린더 공변량 측정용)

**AI Hub 데이터에는 캘린더 일정이 없다.** 그래서 "확정된 일정을 known future covariate로 넣으면 얼마나 좋아지는가"는 AI Hub로 측정할 수 없다. 이 질문에만 합성 데이터를 쓴다.

`tools/forecast_bench/generate_synthetic.py`:

- 고정비: 매월 특정일 결정론적
- 반복 소비: 감마 분포 간격의 갱신 과정 (장보기 ~10일, 미용실 ~6주)
- 캘린더 연동: 일정 이벤트에 금액을 붙임 → **이것이 공변량**
- 소액 잡지출: 요일별 강도가 다른 포아송
- 금액: 카테고리별 로그정규. **μ, σ를 `data/baseline_prices.json`에 캘리브레이션한다** — 서울열린데이터광장 상권분석 카드매출 기반이므로 "실제 공표 통계에 앵커링된 합성 데이터"라고 방어할 수 있다.
- 사람별 파라미터는 인구 사전분포에서 추출 (계층 구조) → 콜드스타트 실험에 필요

---

## 3. 분할 규칙

- **시간 순 홀드아웃.** 마지막 8주를 테스트로 뗀다.
- **랜덤 분할 금지.** 미래 정보 누출이다.
- 콜드스타트 실험용으로 사용자 20%를 별도 홀드아웃 (학습에 한 번도 쓰지 않음).

---

## 4. 벤치마크 사다리

아래에서 위로 쌓는다. **각 단이 직전 단 대비 얼마를 벌었는지**가 결과물의 핵심이다.

| 단 | 모델 | 온디바이스 | 비고 |
|---|---|:---:|---|
| **R0** | 카테고리 중앙값 (현재 방식) | ✅ | `estimate.py` 로직을 그대로 포팅. **이기지 못하면 아무 의미 없다** |
| **R1** | 계절 naive (직전 4주 같은 주 중앙값), 일평균×남은일수 | ✅ | 로드맵에 약속한 "단순 평균 기준선" |
| **R2** | 허들 2단 + LightGBM 분위 회귀 | ✅ | 1단 P(발생) 분류, 2단 E[금액\|발생] 분위 회귀(log 타깃, α=0.1/0.5/0.9) |
| **R3** | R2 + 계층 shrinkage 사전분포 | ✅ | `w = n/(n+k)`로 개인 추정과 인구 사전을 혼합. 콜드스타트 대응 |
| **R4** | R3 + CQR (Conformalized Quantile Regression) | ✅ | 보정 집합의 잔차 분위수로 구간 보정. **분포 가정 없이 커버리지 보장** |
| **R5** | Chronos-2 zero-shot | ❌ 서버 | 상한선 측정. 공변량 유무 두 조건으로 각각 측정 |
| R6 | TabPFN-3 (선택) | ❌ | **상용 배포 라이선스 필요.** 상한선 참고용만. 슬라이드에 성능 수치 쓰지 말 것 |

R0~R4가 **제품에 넣을 후보**이고, R5~R6은 "우리가 상한선의 몇 %를 회수했는가"를 말하기 위한 참조선이다.

### Chronos-2 사용법 (컨테이너에서 검증된 사실)

```
pip install "chronos-forecasting>=2.0"   # 검증 버전 2.3.1
```

```python
from chronos import BaseChronosPipeline
pipeline = BaseChronosPipeline.from_pretrained(
    "amazon/chronos-2",
    device_map="cuda" if torch.cuda.is_available() else "cpu",   # ← CPU 폴백 필수
)
pred = pipeline.predict_df(
    context_df,                    # id_column, timestamp_column, target + 나머지 컬럼 = past-only 공변량
    future_df=future_df,           # ← known future covariates. 이게 Chronos-2를 쓰는 이유다
    prediction_length=8,
    quantile_levels=[0.1, 0.5, 0.9],
    id_column="item_id",
    timestamp_column="week_start",
    target="amount_sum",
)
```

확인된 사실:
- **120M 파라미터, encoder-only, Apache 2.0.** CPU 추론 가능 (AirPassengers 12스텝이 CPU에서 18초, 모델 다운로드 포함).
- `df`의 target·id·timestamp 외 나머지 컬럼은 **자동으로 past-only 공변량**이 된다.
- `future_df`에 넣은 컬럼은 **known future covariates**로 취급된다.
- `target`에 컬럼 리스트를 주면 다변량. **T3(카테고리별)를 다변량으로 묶어 예측하면 카테고리 간 상관을 태울 수 있다** — 이걸 T3에서 반드시 시도한다.
- 최대 context 8192, 예측 최대 1024 스텝.
- 시계열에 시간 간격(gap)이 있으면 안 된다.

`item_id`는 `f"{user_id}|{category}"` 조합으로 만든다.

**공변량으로 넣을 것** (AI Hub에 있는 것만):
- known future: 그 주의 공휴일 수, 급여일 포함 여부, 월중 주차, 월말 여부
- past-only: 직전 주 tx_count, 직전 4주 이동평균
- 합성 데이터에서만: **확정된 캘린더 일정 금액 합** ← 이 컬럼의 기여도를 따로 보고한다

---

## 5. 평가 지표

**MAPE를 주지표로 쓰지 마라.** 소액 거래에서 발산한다.

- 점 예측: **WAPE**(주지표), **MASE**(계절 naive 기준)
- 확률 예측: **CRPS**(주지표), pinball loss(0.1/0.5/0.9)
- 구간: **80% 커버리지** — 80% 구간이 실제로 80%를 덮는지. 앱이 "신뢰도 55%"를 표시하고 있으므로 이 지표가 정직성의 증거다
- 캘리브레이션: reliability diagram (예측 확률 vs 실제 빈도)
- 의사결정: **저축 목표 달성 확률의 캘리브레이션.** 사용자가 실제로 보는 숫자다

---

## 6. 콜드스타트 실험 (별도 섹션으로 보고)

홀드아웃 사용자의 이력을 `n ∈ {0, 2, 5, 20, 50}`건으로 절단해 각 단을 평가한다.

- R0은 n=0에서 아예 예측 불가 (또는 규칙 폴백)
- R3의 사전분포가 여기서 값어치를 증명해야 한다
- 결과를 "거래 n건일 때 WAPE" 꺾은선 그래프로 낸다 → **이 그래프 한 장이 계층 구조를 정당화한다**

---

## 7. 증류 (승자를 기기로 옮기기)

R5가 이기더라도 **Chronos-2를 기기에 넣지 않는다.** 대신:

1. 서버에서 R5로 인구 수준 예측을 돌린다
2. 결과를 카테고리별 파라미터 표로 추출 → `data/forecast_prior.json`
   - 카테고리별 μ, σ, 반복 주기, 요일 계수, 분위 오프셋, shrinkage k
3. 이 표는 `baseline_prices.json`과 같은 형태로 Firestore 읽기 전용 배포 경로를 그대로 쓴다
4. Swift에서 표 + 개인 이력으로 shrinkage 적용 → 온디바이스 추론
5. **`probability.py`의 σ=100,000을 몬테카를로 시뮬레이션 분포로 대체한다.** R2~R4의 분위 예측에서 주간 총액 분포를 샘플링하면 목표 달성 확률이 분포에서 직접 나온다

증류된 표로 재평가해서 **원본 R5 대비 성능 손실률을 반드시 보고한다.**

---

## 8. 산출물

```
tools/forecast_bench/
  generate_synthetic.py    합성 패널 생성 (baseline_prices.json 캘리브레이션)
  load_aihub.py            AI Hub → canonical 변환 (스키마 조사 후 작성)
  features.py              피처 엔지니어링
  models.py                R0~R6
  metrics.py               WAPE/MASE/CRPS/pinball/coverage
  distill.py               승자 → forecast_prior.json
  run_bench.py             오케스트레이터
docs/aihub-schema-notes.md          컬럼 조사 + 이용약관 확인 결과
docs/competition/forecast-bench-YYYYMMDD/
  results.csv              단×지표 전체 결과
  results.md               해석 + 한계 + 재현 커맨드
  coldstart.png            거래 n건 대비 WAPE
  reliability.png          확률 캘리브레이션
data/forecast_prior.json   증류된 온디바이스 파라미터 표
```

---

## 9. 진행 순서 (각 단계 검증 후 다음으로)

```
1. AI Hub zip 조사 → 컬럼·약관 기록          검증: docs/aihub-schema-notes.md 작성 완료
2. canonical 변환 (5,000명 샘플)              검증: tx/weekly parquet 행 수·결측·기간 출력
3. 합성 생성기                                검증: 금액 분포가 baseline_prices.json과 같은 자리수
4. metrics.py                                 검증: 알려진 정답으로 단위 테스트 통과
5. R0·R1 구현                                 검증: R0가 estimate.py와 같은 값을 내는지 대조
6. R2~R4                                      검증: 각 단이 R0 대비 WAPE 개선폭 출력
7. R5 (Chronos-2, 공변량 유/무)                검증: CPU에서 완주. 공변량 기여도 분리 보고
8. 콜드스타트 실험                             검증: coldstart.png
9. 증류 + probability.py 대체                  검증: 손실률 보고 + pytest 통과
10. results.md 작성                            검증: 한계 절 포함
```

---

## 10. 하지 말 것

- **랜덤 분할 금지.** 시간 순만.
- **MAPE 주지표 금지.**
- **Chronos-2·TabPFN을 기기에 넣으려 하지 말 것.** 서버측 상한선 측정용이다.
- **합성 데이터 성능을 실사용자 성능이라고 쓰지 말 것.** "합성 데이터 기준"을 항상 병기한다.
- **AI Hub 원본을 커밋하지 말 것.**
- **결과가 R0보다 나쁘면 그대로 보고할 것.** 하이퍼파라미터를 주워 맞춰서 이기게 만들지 말 것. 지면 "현재 방식이 이 데이터에서는 충분히 강하다"가 정직한 결론이고, 그것도 발표할 수 있는 결과다.
- 기존 테스트를 깨뜨리지 말 것. 금액은 iOS `BudgetEngine` · 백엔드 `app/data.py` · 양쪽 테스트가 같은 값을 보도록 잠겨 있다.

---

## 11. 성공 기준

1. `results.md`에 R0~R5 전 단의 WAPE·MASE·CRPS·커버리지가 한 표에 있다
2. 온디바이스 가능한 최선(R4 이하)이 **R0 대비 WAPE 개선폭**으로 명시된다
3. 콜드스타트 그래프가 사전분포의 값어치를 보여준다
4. `forecast_prior.json`이 생성되고, 증류 손실률이 보고된다
5. `probability.py`의 σ 하드코딩이 제거되거나, 제거하지 못한 이유가 적힌다
6. 한계 절에 최소 다음이 포함된다 — 합성 데이터 기반이라는 점, 실사용자 홀드아웃은 미검증이라는 점, AI Hub 데이터가 합성이라는 점