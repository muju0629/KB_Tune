# KB Tune 8주 개인화 파일럿 프로토콜

## 목적

주 2회 고영향 확인이 다음 주 카드 소비 예측을 즉시 보정하는지, 그리고 `futureDefault` 피드백을 반영한 개인 Bayesian 레이어가 직접 질문하지 않은 항목까지 일반화하는지 실제 사용자 데이터로 검증한다.

현금 결제는 수집·학습·평가에서 제외한다.

## 사전 결론과 검증 가설

- 합성 실험에서 `thisOccurrence`를 이용한 즉시 보정 효과는 확인했다.
- 정답 누설을 제거한 합성 실험에서 개인 Bayesian 레이어의 미질문 일반화는 확인하지 못했다.
- 따라서 파일럿 전 대외 표현은 **“주 2회 확인을 통한 예측 보정”**으로 제한한다.
- **“사용할수록 빠르게 개인화된다”**는 표현은 아래 1차 성공 기준을 통과한 뒤에만 사용한다.

## 참여자와 기간

- 기간: 연속 8주
- 모집 범위: 20~50명
- 권장 목표: 40명 이상, 중도 이탈을 고려해 최대 50명 모집
- 20명만 확보되면 통계적 입증이 아닌 탐색 파일럿으로 명시
- 사전 데이터: 참여 전 최소 8주, 권장 12주 이상의 카드 승인 이력
- 필수 조건: 카드 데이터 연결, 만 19세 이상, 연구 동의
- 선택 조건: 캘린더 연결. 미연결 여부는 층화 변수와 결과 보고 항목으로 기록

## 실험 설계

참여자를 1:1로 무작위 배정한다.

| 조건 | 모델 입력 | 사용자 질문 | 개인 상태 갱신 |
|---|---|---|---|
| Passive | 카드 이력 + 캘린더 | 노출하지 않음 | 없음 |
| Active | 카드 이력 + 캘린더 | 주 2회 | `futureDefault` 동의 응답만 shadow 상태 갱신 |

무작위 배정은 사전 4주 소비 규모, 사전 WAPE, 캘린더 연결 여부로 층화한다. 학습 효과가 다음 기간에 남기 때문에 AB/BA 교차 실험은 사용하지 않는다.

Passive에도 매주 동일한 질문 선택 정책을 그림자 실행해 두 개의 `shadow_question`을 기록한다. 평가 시 두 조건 모두 같은 규칙으로 질문 대상 카테고리를 제외하여 미질문 지표의 분모를 맞춘다.

합성 재실험에서 개인 Bayesian 보정이 악화됐으므로 사용자 화면에는 LightGBM과 `thisOccurrence` 즉시 보정 결과만 사용한다. Bayesian 후보는 Active 참여자에게 노출하지 않는 shadow 예측으로 저장하고, 실제 소비가 확정된 뒤 동일 입력의 `LightGBM Active`와 비교한다.

## 주 2회 피드백

### 즉시 보정 1회: `thisOccurrence`

- 예: “다음 주 결혼식 비용은 약 10만 원으로 보면 될까요?”
- 발생 여부, 예상 금액, 일정 취소·이동을 확인
- 해당 발생 건의 예측에만 반영하고 사용 후 만료
- 개인 Bayesian 충분통계량에는 넣지 않음

### 장기 학습 1회: `futureDefault`

- 예: “앞으로도 팀 외식은 보통 월 2회, 회당 3만 원 정도인가요?”
- 빈도 또는 발생률과 평소 금액을 별도로 확인
- “앞으로 적용”에 명시적으로 동의한 응답만 개인 상태에 반영
- 현재 주 예측을 직접 덮어쓰지 않음
- 동일 사용자×카테고리는 4주 동안 재질문하지 않음

## 사전 등록 지표

### 1차 지표

8주차와 보조적으로 5~8주 평균의 **미질문 총액 WAPE**를 비교한다.

- 분석 단위: 참여자
- 1차 비교: Active 참여자 내 `LightGBM Active WAPE - Personal Shadow WAPE`
- 보조 비교: `Passive WAPE - Active WAPE`
- 평가 제외: Active 실제 질문과 Passive 그림자 질문에 해당하는 사용자×주×카테고리
- 추정: 참여자 단위 bootstrap 95% 신뢰구간과 원자료 점추정치
- 1차 성공 기준: Personal Shadow 개선폭의 95% 신뢰구간 하한이 0보다 큼
- 배포 안전 기준: 전체 WAPE가 LightGBM Active보다 악화되지 않고 80% 예측구간 커버리지가 5%p 넘게 하락하지 않음

### 2차 지표

- 전체 카드 총액 WAPE
- 카테고리별 Macro WAPE
- 발생확률 Brier score
- 80% 예측구간 커버리지와 중앙 구간 폭
- 주차별 Active–Passive 개선 곡선

### 사용자 부담 및 안전 지표

- 질문 노출·응답·수정·건너뛰기 비율
- 질문당 응답 시간
- 주간 질문 알림 해제율과 파일럿 중도 이탈률
- `futureDefault` 철회 건수와 철회 후 상태 삭제 성공률
- 사용자 승인 없는 계획·결제 변경 0건

## 판정 규칙

| 결과 | 허용 표현 |
|---|---|
| 전체 WAPE만 개선 | “주 2회 확인으로 예측을 보정한다” |
| 미질문 WAPE 개선, 95% 신뢰구간이 0 포함 | “개인화 가능성을 관찰했다” |
| 미질문 WAPE 개선, 95% 신뢰구간 하한 > 0, 안전 기준 통과 | “8주 사용 중 미질문 항목까지 개인화가 확장됐다” |
| 미질문 WAPE 악화 | 개인 Bayesian 레이어 중단 또는 사전분포·단위 재설계 |

표본이 20명에 그치면 신뢰구간 통과 여부와 무관하게 탐색 결과로만 보고하며 확증 표현을 사용하지 않는다.

## 이벤트 데이터 계약

모든 이벤트는 가명 참여자 ID와 모델 버전을 포함한다.

| 이벤트 | 필수 필드 |
|---|---|
| `forecast_created` | participant_id, model_version, created_at, target_week, category, probability, conditional_amount, interval_low, interval_high |
| `question_eligible` | participant_id, target_week, category, priority, rank, assigned_arm |
| `feedback_prompted` | participant_id, prompt_id, scope, category, prompted_at |
| `feedback_answered` | prompt_id, answered_at, response_type, occurrence_probability, typical_amount, category_correction, future_apply_consent |
| `feedback_revoked` | prompt_id, revoked_at, state_deleted_at |
| `actual_observed` | participant_id, target_week, category, card_amount, finalized_at |

`thisOccurrence`와 `futureDefault` 이벤트는 저장 단계부터 별도 scope로 구분한다. 장기 상태 갱신에는 `future_apply_consent=true`인 `futureDefault`만 허용한다.

## 분석 잠금과 품질 점검

- 파일럿 시작 전에 모델, 질문 선택 정책, 지표, 제외 규칙을 버전으로 고정
- 실제값을 보기 전에 주차별 예측 스냅샷 저장
- 결제 취소·환불은 사전에 정한 정산 지연 후 실제값으로 확정
- 참여자별 카드 데이터 누락일과 캘린더 연결 상태 보고
- 실험 종료 전 모델 파라미터 변경 금지
- 중간 결과를 보고 질문 수, prior weight, 성공 기준을 변경하지 않음
- 실패 사례 최소 1건과 원인을 최종 보고서에 포함

## 개인정보와 온디바이스 원칙

- 개인 Bayesian 충분통계량은 기기 내 저장을 기본값으로 함
- 서버 분석에는 원거래 설명 대신 가명 ID, 카테고리, 주 단위 금액, 예측·응답 이벤트만 전송
- 참여자가 `futureDefault`를 철회하면 연결된 충분통계량을 재계산하거나 삭제
- 파일럿 종료 시 보존 기간과 삭제 방법을 사전에 고지
- 모델은 조정안을 제안할 수 있으나 일정·이체·결제를 자동 변경하지 않음

## 로컬 데이터 사용 범위

- 경기 카드소비 파일: 하루·포천 집계이므로 카테고리 객단가 사전값의 약한 보정에만 사용
- AI Hub 금융 합성 월 패널: 개인 소비의 지속성 가정과 스트레스 테스트에만 사용
- 서울 시민생활 예제: 소비 거래가 아닌 행정동·성별·연령대 집계이므로 모델 학습에는 사용하지 않고 모집 층화나 세그먼트 참고에만 사용
- 위 자료를 실제 사용자 성능 검증의 대체물로 사용하지 않음

## 최종 산출물

- 1~8주 Active–Passive 성능 곡선
- 전체·미질문 WAPE와 사용자 bootstrap 95% 신뢰구간
- Brier score, 예측구간 커버리지·폭
- 질문 응답률·이탈률·철회율
- 모델이 개선된 사례와 악화된 사례
- 대외 표현 가능 여부를 판정 규칙에 따라 명시한 1페이지 요약
