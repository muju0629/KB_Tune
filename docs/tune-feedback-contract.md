# Tune 피드백 데이터 계약 v0

## 목적

사용자가 알려준 미래 일정 정답을 현재 예측에 반영하는 **즉시 보정**과, 반복되는 개인 성향을 학습하는 **장기 학습**을 분리한다. 두 효과를 같은 지표로 섞지 않는다.

## 공통 이벤트

```text
FeedbackEvent
  id: UUID
  createdAt: Date
  predictionID: String
  eventID: UUID?                 // 특정 일정이면 존재
  category: String
  signal: occurrence | amount | date | category | protection
  scope: thisOccurrence | futureDefault
  originalValue: String?
  responseValue: String
  source: proactiveCard | eventEdit | dailyReview
  consentVersion: Int
  expiresAt: Date?               // 즉시 보정에만 사용
  revokedAt: Date?
```

## 즉시 보정

`scope = thisOccurrence`

- 예: “다음 주에도 있나요?”, “이번 금액은 7만 원이 맞나요?”, 일정 취소·이동.
- 해당 예측 발생 건과 예산 장부에만 반영한다.
- 기본 만료는 일정 종료 또는 14일이다.
- 개인 Bayesian 충분통계량에는 넣지 않는다.
- 성능 보고에서는 `queried item`으로 표시해 직접 확인 효과를 분리한다.

## 장기 학습

`scope = futureDefault`

- 예: “앞으로 데이트 비용은 보통 이 정도로 볼까요?”, “이 가맹점은 항상 경조사로 분류할까요?”
- 사용자가 ‘앞으로도 적용’ 의사를 명시한 경우에만 저장한다.
- 카테고리별 발생 Beta 상태, 로그금액 보정 상태, 취소율 상태 중 해당 항목만 갱신한다.
- 사용자는 설정에서 항목별 학습값과 근거를 보고 철회할 수 있다.
- 철회 시 원본 피드백과 파생 충분통계량을 함께 다시 계산한다.

## 온디바이스 개인 상태

```text
PersonalCategoryState
  category: String
  occurrenceYes: Double
  occurrenceNo: Double
  logAmountWeightedSum: Double
  logAmountWeight: Double
  cancellationYes: Double
  cancellationNo: Double
  evidenceFeedbackIDs: [UUID]
  updatedAt: Date
```

- 글로벌 LightGBM 모델 파일은 피드백마다 다시 학습하지 않는다.
- 기기에서는 카테고리별 충분통계량만 갱신한다.
- 개인 보정은 인구 사전분포로 수축해 표본 1~2건의 과대반응을 막는다.
- 응답의 신뢰도는 1로 고정하지 않고, 확인 방식과 이후 실제 카드 기록의 일치율로 가중한다.

## 예측 결합

```text
globalOccurrence = LightGBM 발생확률
globalAmount = LightGBM 조건부 금액

personalOccurrence = logit(globalOccurrence) + 개인 발생 odds 보정
personalAmount = globalAmount × exp(개인 로그금액 보정)

즉시 보정 답변이 있으면 해당 발생 건만 보수적으로 덮어쓴다.
```

사용자 확인 “있음”을 100%로 두지 않는다. v0에서는 응답 신뢰도를 반영해 85~90% 범위로 시작하고 실제 파일럿에서 보정한다.

## 평가 분리

| 지표 | 포함 범위 | 의미 |
|---|---|---|
| Final system WAPE | 전체 | 사용자가 실제로 보는 최종 성능 |
| Queried WAPE | 현재 주 질문 항목 | 직접 확인 효과 |
| Unqueried WAPE | 동일 질문 후보를 양 조건에서 제외 | 장기 학습 일반화 |
| Occurrence Brier | 사용자×주×카테고리 | 발생확률 보정 |
| Interval coverage/width | 다음 주 총액 | 불확실성의 정직성 |
| Questions per user-week | 응답 여부와 무관 | 사용자 부담 |

“빠르게 개인화된다”는 주장은 Unqueried WAPE 개선폭의 사용자 bootstrap 95% 구간이 0보다 클 때만 사용한다.

## 보관·감사 규칙

- 원본 피드백, 적용 범위, 모델 상태 변화, 예측 전후값을 감사 로그에 남긴다.
- 승인 전에는 일정·금액·카테고리를 변경하지 않는다.
- 민감한 일정 제목과 금액은 기기 밖으로 보내지 않는다.
- 장기 학습값은 설정에서 카테고리별 초기화할 수 있어야 한다.
