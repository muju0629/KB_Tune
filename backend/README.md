# KB Tune — 금융 에이전트 백엔드

소비 데이터를 **결정론적 엔진**으로 계산하고, 그 위에서 **Claude**가 설명·판단·문장만 만드는
"금융 라이프 에이전트" API. 단순한 LLM 프롬프트 래퍼가 아니라, 검증 가능한 재무 모델이 핵심이다.

## 설계 원칙 — 숫자는 코드, 판단은 LLM

```
요청 → [결정론 엔진] → PlanResult(모든 숫자) → [Claude] 설명/판단 → [groundedness 검증] → 응답
                └ 예산배분 · 몬테카를로 목표확률 · 위험탐지 · 조정안 생성
```

- **계획의 숫자는 엔진이 만든다.** 사용 가능액·확률·조정안은 전부 파이썬 엔진이 계산한다.
- **LLM은 우리가 준 데이터 안에서만 말한다.** 준 값을 더하거나 비교하는 건 되고
  (`"카페 12,000 + 8,000 = 20,000원"`), 없는 값을 만들어내는 건 안 된다.
  `eval/groundedness.py` 가 그 경계를 지킨다.
- **틀린 숫자에만 표시를 붙인다.** 근거 없는 값을 찾으면 그 숫자 뒤에 `(확인 필요)` 를 붙이고
  나머지 문장은 살린다. 셋 이상이면 답변 대부분이 지어낸 것이므로 템플릿으로 바꾼다.
  어느 쪽이든 `blocked_numbers` 에 남겨 **평가에서는 모델 실패로 집계**한다 —
  안전 폴백과 모델 품질을 같은 100%로 포장하지 않는다.
- **키가 없어도 전부 동작한다.** 키 없이 실행하면 엔진은 그대로 계산하고
  코칭/대화는 템플릿으로 응답한다. → 심사자가 키 없이 바로 실행 가능.

## 구조

```
app/
├─ engine/            # 결정론적 금융 엔진 (LLM 없음)
│  ├─ budget.py       #   가처분·주예산·이번 주 사용 가능액
│  ├─ probability.py  #   적금 목표 달성 확률 (시드 고정 몬테카를로 20,000회)
│  ├─ risk.py         #   위험 일정 탐지 + 조정안 생성
│  ├─ analysis.py     #   카테고리 분석·급증 탐지
│  └─ plan.py         #   오케스트레이션 → PlanResult(숫자 단일 출처)
├─ llm/               # Claude 레이어 (설명·판단만)
│  ├─ prompts.py      #   엔진 숫자에 접지된 프롬프트
│  ├─ coach.py        #   구조화 출력 + groundedness 폴백
│  └─ chat.py         #   스트리밍 대화
├─ eval/              # 평가
│  ├─ golden.py       #   엔진 정합성 골든 케이스
│  ├─ groundedness.py #   LLM이 엔진 숫자만 쓰는지 검사
│  └─ runner.py       #   /api/eval
├─ data.py            # 성제의 2026년 7월 캘린더 기반 데모 입력
├─ models.py          # Pydantic 스키마
└─ main.py            # FastAPI 라우트
tests/test_engine.py  # pytest 회귀 테스트
```

## 실행 (키 없이도 됨)

```bash
cd backend
./run.sh                       # venv 생성 + 설치 + 서버(:8000)
# 또는 수동:
python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt
./.venv/bin/uvicorn app.main:app --reload
```

Claude 코칭을 켜려면 `.env`에 키만 넣으면 된다 (`.env.example` 참고):

```
ANTHROPIC_API_KEY=sk-ant-...
```

## 엔드포인트

| 메서드 | 경로 | 설명 |
|---|---|---|
| GET | `/api/health` | 상태 + LLM 사용 여부 |
| POST | `/api/plan` | **순수 엔진** 결과(숫자) — 알고리즘 단독 동작 |
| POST | `/api/coach` | 엔진 계획 + 접지된 LLM 코칭 |
| POST | `/api/chat` | 계획을 바꾸는 대화(텍스트 스트리밍) |
| GET | `/api/eval` | 평가 리포트(골든 + groundedness) |
| POST | `/api/estimate` | **① 일정 제목 → 예상 지출** (캘린더 유형 개인화 + 엔진 범위 보정) |
| POST | `/api/extract` | **② OCR 텍스트 → 거래 추출** (`image_base64` 원본은 422로 차단) |
| POST | `/api/categorize` | **③ 가맹점 → 카테고리** (규칙 사전 → 미스만 LLM, 집합 강제) |
| POST | `/api/forecast` | **④ 다음 달 일정·지출 예측** (반복 패턴 탐지) |

### AI를 어디에 쓰는가 — 인식은 AI, 계산은 엔진

| 기능 | AI가 하는 일(비정형→정형) | 엔진이 하는 일(검증) |
|---|---|---|
| ① 예상 지출 | 제목의 의미 파악·세상 지식 추정 | 같은 일정 유형 범위로 보정, 500원 단위 정리 |
| ② 거래 추출 | Apple Vision이 기기 안에서 가맹점·금액 OCR | 서버는 원본 이미지를 거절하고, 결정론 파서가 금액 범위·잔액/합계 줄을 검증 |
| ③ 분류 | 규칙이 놓친 가맹점 분류 | 허용 카테고리 집합 강제(계약 위반 값 폐기) |
| ④ 예측 | (선택) 예측 설명 문장 | 반복 주기 탐지·월 합계 산출 전부 결정론 |

**키가 없어도 4개 모두 동작한다** — 규칙 사전·캘린더 유형·패턴 탐지로 결정론 경로가 항상 존재.

예:
```bash
curl -s localhost:8000/api/plan -X POST -H 'content-type: application/json' -d '{}' | python3 -m json.tool
curl -s localhost:8000/api/eval | python3 -m json.tool
curl -sN localhost:8000/api/chat -X POST -H 'content-type: application/json' \
     -d '{"message":"이번 주 출근비까지 빼면 얼마 남아?"}'
```

## 평가 / 테스트

```bash
./.venv/bin/pytest -q          # 엔진 골든·MC 정합성·groundedness
curl -s localhost:8000/api/eval
```

성제의 2026년 7월 캘린더 기준 엔진 출력(시드 고정 → 항상 동일):

| 방향 | 이번 주 사용 가능액 | 목표 확률 |
|---|---:|---:|
| 줄이기 | 47,720원 | 88% |
| 유지 | 62,000원 | 81% |
| 늘리기 | 80,360원 | 74% |

금액은 2026-07-22 본인 확인값 기준. 7월 일정비는 801,000원(전 항목 확정 — 범위 없음)이고,
출근은 점심 무비용 + 교통·유류 고정비 반영으로 일정 비용 0원이다.

## Render 배포

- Build: `pip install -r requirements.txt`
- Start: `uvicorn app.main:app --host 0.0.0.0 --port $PORT`
- 환경변수: `ANTHROPIC_API_KEY` (선택 — 없어도 동작)

> ⚠️ 무료 티어는 유휴 시 슬립(콜드스타트). 라이브 데모라면 직전에 `/api/health`로 깨워두거나
> 로컬 실행을 백업으로 준비. 심사자가 코드를 직접 받아 실행하는 방식이면 로컬만으로 충분.
