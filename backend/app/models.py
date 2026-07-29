"""요청/응답 스키마. 엔진 출력(결정론적 숫자)과 LLM 출력(언어)을 명확히 분리한다."""
from __future__ import annotations

from typing import Annotated, Literal, Optional

from pydantic import BaseModel, Field

Direction = Literal["reduce", "maintain", "increase"]

# 외부에서 들어오는 값의 상한. 없으면 프롬프트·메모리·API 비용이 요청자 마음대로 커진다.
# 사람이 실제로 쓸 수 있는 범위보다 넉넉하되, 무한하지는 않게 잡는다.
Won = Annotated[int, Field(ge=0, le=100_000_000)]
ShortText = Annotated[str, Field(max_length=40)]
# 앱은 날짜를 '통산일' 하나로 센다 — 7월 1일이 1, 8월 1일이 32, 8월 31일이 62.
# 달을 넘나드는 계산이 정수 덧셈으로 끝나기 때문이다. 그래서 상한이 31이 아니라 62다.
# 31로 두면 8월 일정이 하나라도 섞인 순간 요청 전체가 거절된다.
Day = Annotated[int, Field(ge=1, le=62)]


# ---------- 입력 ----------

class FixedCost(BaseModel):
    name: ShortText
    amount: Won


class Transaction(BaseModel):
    """월중 지출 입력. 데모에서는 캘린더 일정에서 계산한 예상액이다."""
    category: str
    amount: int
    day: int                       # 해당 월의 날짜(1~31)
    month: int = 7                 # 월(히스토리 구분용)
    merchant: str | None = None    # 가맹점 원문(분류의 입력)
    estimate_low: int | None = None
    estimate_high: int | None = None


class PlannedEvent(BaseModel):
    """앞으로의 일정. amount=예상 지출, confirmed=확정 여부(미확정=후보)."""
    title: str
    category: str
    amount: int
    day: int
    confirmed: bool = True
    protected: bool = False
    estimate_low: int | None = None
    estimate_high: int | None = None


class Profile(BaseModel):
    """예산 계산에 실제로 쓰이는 값만 받는다.

    이름·나이는 엔진도 프롬프트도 쓰지 않아서 아예 필드를 두지 않았다.
    안 쓰는 개인정보는 받지 않는 게 가장 확실한 보호다(추가로 보내와도 무시된다).
    """
    role: Annotated[str, Field(max_length=60)] = "대학생 · 인포스탁 인턴"
    monthly_income: Won = 2_200_000
    savings_goal: Won = 800_000
    fixed_costs: Annotated[list[FixedCost], Field(max_length=30)] = Field(default_factory=list)
    direction: Direction = "maintain"
    protected_categories: Annotated[list[ShortText], Field(max_length=30)] = Field(default_factory=list)


class CardBilling(BaseModel):
    """신용카드 청구 사이클. 앱의 BillingCycle 이 계산해 넘긴다.

    '쓴 날'과 '돈 나가는 날'이 다르다는 사실은 월 예산 계산만으로는 드러나지 않는다.
    조언할 때 "다음 달 카드값이 이미 얼마"를 근거로 쓰려면 이 값들이 필요하다.
    """
    due_next: Won = 0          # 다음 결제일에 실제로 빠질 금액
    usage: Won = 0             # 이번 이용기간 이용금액
    carryover: Won = 0         # 할부로 그 다음 결제일에 넘어가는 금액
    pay_label: ShortText = ""        # "8월 14일"
    next_pay_label: ShortText = ""   # "9월 14일"
    days_until_pay: Annotated[int, Field(ge=0, le=366)] = 0
    days_until_close: Annotated[int, Field(ge=0, le=366)] = 0  # 이용기간 마감까지 남은 일수
    close_label: ShortText = ""      # "7월 26일"


class UpcomingEvent(BaseModel):
    """오늘 이후로 잡혀 있는 지출 일정."""
    # title 은 사용자가 캘린더에 직접 쓴 자유 문자열이다.
    # 프롬프트에 들어가기 전 security.safe_text 로 한 번 더 무해화한다.
    # 기본값이 빈 문자열인 건 앱이 동의 없이는 제목을 보내지 않기 때문이다 —
    # 제목이 없으면 유형과 금액만으로 답을 만든다.
    day: Day
    title: Annotated[str, Field(max_length=80)] = ""
    amount: Won
    category: ShortText = "기타"


class AppNumbers(BaseModel):
    """앱의 BudgetEngine 이 이미 계산해 화면에 띄운 값.

    백엔드 엔진이 같은 값을 다시 계산하면 시드 데이터 차이·할부 이월분 반영 여부 때문에
    화면과 어긋난다. 화면에 70,000원이 떠 있는데 챗봇이 다른 금액을 말하면 안 되므로,
    앱이 보낸 값이 있으면 그쪽을 단일 진실로 삼는다.
    """
    weekly_available: int
    probability: int
    remaining_budget: int
    spent_to_date: int
    installment_carryover: int = 0
    month_end_remaining: int | None = None


class PlanRequest(BaseModel):
    """미지정 시 데모 페르소나 사용. 일부 필드만 덮어쓸 수 있음."""
    profile: Optional[Profile] = None
    today: Day = 22  # 2026년 7월 캘린더 기준일
    include_candidate: bool = False  # 위험 후보 일정을 계획에 반영할지
    card: Optional[CardBilling] = None
    upcoming: Annotated[list[UpcomingEvent], Field(max_length=200)] = Field(default_factory=list)
    # 이미 쓴 지출. "7월에 카페에 얼마 썼어?"처럼 지난 소비를 묻는 질문은 이게 없으면
    # 답할 수 없다. 형식은 upcoming 과 같고, 제목은 앱이 보내지 않으므로 여기서도 비어 있다.
    past: Annotated[list[UpcomingEvent], Field(max_length=200)] = Field(default_factory=list)
    app_numbers: Optional[AppNumbers] = None


class ChatHistoryItem(BaseModel):
    """사용자가 선택해 보낸 짧은 대화 문맥.

    system 역할은 허용하지 않는다. 과거 대화는 어디까지나 user/assistant 메시지이며,
    서버의 보안·접지 지시보다 높은 우선순위를 가질 수 없다.
    """
    role: Literal["user", "assistant"]
    content: Annotated[str, Field(min_length=1, max_length=600)]


class ChatRequest(PlanRequest):
    message: Annotated[str, Field(min_length=1, max_length=2_000)]
    history: Annotated[list[ChatHistoryItem], Field(max_length=8)] = Field(default_factory=list)


class SearchRequest(BaseModel):
    """웹 검색 요청 — 질문 한 줄만 받는다.

    계획·카드·일정 필드를 일부러 넣지 않았다. 이 경로로는 재무 데이터가 나갈 수 없다.
    """
    query: Annotated[str, Field(min_length=1, max_length=200)]


# ---------- 대화 에이전트 ----------

class AgentEventRef(BaseModel):
    """이미 잡혀 있는 일정 한 건 — **제목 없이** 번호로만 가리킨다.

    옮기고 지우는 데 제목이 필요 없다. 번호와 날짜·유형만 있으면 모델이 "그 여행"을
    지목할 수 있고, 제목은 기기 밖으로 나갈 이유가 사라진다. 제목으로 맞추던 방식은
    비식별화가 '카페 약속'을 '[이름] 약속'으로 바꿔 놓으면 앱에서 못 찾는 문제도 있었다.
    """
    ref: Annotated[int, Field(ge=1, le=99)]
    day: Day
    category: str
    amount: Won


class AgentRequest(ChatRequest):
    """대화 한 턴. message 는 앱이 기기에서 가명처리한 문장이다.

    이름·연락처·저장된 일정 제목은 `AgentService.sanitize()` 가 앱에서 이미 가렸다.
    서버는 그걸 되돌릴 수 없고, 되돌리려 하지도 않는다.
    """
    # 앱이 웹 검색 동의를 받았는지. 없으면 검색 도구를 아예 안 준다.
    may_search: bool = False
    # 오늘 통산일 — 상대 날짜("모레")를 절대 날짜로 바꾸는 데 쓴다.
    today: Day = 22
    # 이미 잡혀 있는 일정. 제목은 안 싣는다 — 번호로 가리키면 되기 때문이다.
    events: Annotated[list[AgentEventRef], Field(max_length=40)] = Field(default_factory=list)


class AgentAction(BaseModel):
    """모델이 제안한 동작. 실행은 앱이 하고, 사용자가 버튼을 눌러야 일어난다.

    서버는 사용자 데이터를 갖고 있지 않아서 실행할 수도 없다. 여기 담기는 건
    '이렇게 하자'는 제안뿐이다.
    """
    kind: Literal["add_event", "move_event", "update_amount", "delete_event"]
    day: Day
    # add_event 에만 쓴다. 나머지는 ref 로 기존 일정을 가리킨다.
    title: Annotated[str, Field(max_length=40)] = ""
    # 옮기기·금액 고치기·지우기가 대상으로 삼는 기존 일정 번호.
    ref: Annotated[int, Field(ge=1, le=99)] | None = None
    category: str | None = None
    amount: Won | None = None      # 비우면 앱이 기기 안의 기준 금액 표에서 채운다
    to_day: Day | None = None      # move_event 전용
    label: Annotated[str, Field(max_length=30)]   # 버튼에 쓸 말


class AgentResult(BaseModel):
    reply: str
    actions: list[AgentAction] = Field(default_factory=list)
    # 검색을 실제로 했다면 나간 질의와 출처를 그대로 보여준다 — 무엇이 나갔는지 감출 이유가 없다.
    searched_query: str | None = None
    sources: list[str] = Field(default_factory=list)
    method: str = "llm"            # llm | llm+web | template


# ---------- 엔진 출력(결정론적) ----------

class CategoryStat(BaseModel):
    name: str
    monthly_avg: int
    share: float  # 전체 대비 비중(0~1)


class SpendingAnalysis(BaseModel):
    period: str
    monthly_variable_avg: int
    categories: list[CategoryStat]
    top_category: str
    anomalies: list[str]


class Adjustment(BaseModel):
    id: str
    title: str
    detail: str
    weekly_available: int
    probability: int
    protects_user: bool  # 보호 소비를 지키는 안인지


class RiskAssessment(BaseModel):
    has_risk: bool
    event_title: Optional[str] = None
    amount: Optional[int] = None
    over_by: Optional[int] = None            # 이번 주 남는 금액이 이만큼 줄어듦
    probability_if_added: Optional[int] = None
    probability_now: Optional[int] = None
    summary: Optional[str] = None


class PlanResult(BaseModel):
    """엔진이 계산한 계획 상태. LLM은 이 숫자만 인용한다."""
    direction: Direction
    disposable_month: int
    variable_spent_to_date: int
    remaining_budget: int
    remaining_weeks: int
    weekly_budget: int
    committed_this_week: int
    weekly_available: int
    probability: int
    savings_goal: int
    month_estimate_low: int
    month_estimate_high: int
    month_end_remaining_low: int
    month_end_remaining_high: int
    estimate_basis: str
    protected_summary: str
    analysis: SpendingAnalysis
    risk: RiskAssessment
    adjustments: list[Adjustment]
    # LLM/평가가 인용해도 되는 숫자 화이트리스트
    grounded_numbers: list[int]


# ---------- AI 기능 1: 일정 → 예상 지출 추정 ----------

class EstimateRequest(BaseModel):
    title: Annotated[str, Field(min_length=1, max_length=80)]
    day: Day | None = None
    # 공개 통계 기준값에 연령 배수를 적용할 때만 쓴다. 선택 입력이라 비어 오는 게 정상이고,
    # 저장하지 않는다. 나이 자체보다 좁은 정보를 받으려고 만 나이 대신 10년 단위로 받는다.
    age_bucket: Literal["20", "30", "40", "50"] | None = None


class EstimateResult(BaseModel):
    title: str
    category: str
    amount: int          # 예상 지출(엔진이 최종 검증·보정한 값)
    low: int             # 같은 일정 유형의 예상 하한
    high: int            # 같은 일정 유형의 예상 상한
    confidence: float    # 0~1
    basis: str           # 사용자에게 보여줄 근거 한 줄
    method: str          # rule | history | baseline | llm
    llm_raw: int | None = None   # LLM 원안(엔진 보정 전) — 투명성


# ---------- 웹 검색으로 금액 찾기 (동의했을 때만) ----------

class SearchCostRequest(BaseModel):
    """검색어 하나뿐이다. 계획·카드·일정 필드를 **일부러** 두지 않았다.

    이 통로는 질의가 검색 엔진까지 나간다. 받을 칸이 있으면 언젠가 채워 보내게 되므로
    칸 자체를 만들지 않는다. 앱은 `SearchQuery.make()` 로 코드에 있는 말만 조립해
    보내고, 일정 제목 원문은 여기 도달할 방법이 없다.
    """
    query: Annotated[str, Field(min_length=2, max_length=60)]


class SearchCostResult(BaseModel):
    amount: int | None       # 1인 기준. 못 찾으면 None
    low: int | None
    high: int | None
    basis: str               # 사용자에게 보여줄 근거 한 줄
    sources: list[str] = Field(default_factory=list)   # 참고한 문서 제목·주소
    method: str              # web | unavailable


# ---------- AI 기능 2: 캡처 이미지 → 거래 추출 ----------

class ExtractRequest(BaseModel):
    # 상한은 본문 크기 제한(config.MAX_BODY_BYTES)의 2차 방어선이다.
    # Content-Length 없이 오는 chunked 요청은 미들웨어가 못 막으므로 여기서 잘린다.
    text: Annotated[str, Field(max_length=20_000)] | None = None          # iOS Vision(온디바이스 OCR) 결과
    # 하위 호환 스키마로만 남아 있고 엔드포인트는 항상 422로 거절한다.
    image_base64: Annotated[str, Field(max_length=1_400_000)] | None = None


class ExtractedTransaction(BaseModel):
    merchant: str
    amount: int
    category: str
    confidence: float


class ExtractResult(BaseModel):
    transactions: list[ExtractedTransaction]
    total: int
    method: str          # ocr-rule | on-device-required | none
    warnings: list[str] = Field(default_factory=list)


# ---------- AI 기능 3: 거래 → 카테고리 자동 분류 ----------

class CategorizeRequest(BaseModel):
    # 개수 상한이 없으면 한 번의 요청으로 LLM 프롬프트를 무한정 키울 수 있다.
    merchants: Annotated[list[ShortText], Field(max_length=100)]


class CategoryGuess(BaseModel):
    merchant: str
    category: str
    confidence: float
    method: str          # rule | llm | fallback


class CategorizeResult(BaseModel):
    results: list[CategoryGuess]
    rule_hit_rate: float


# ---------- AI 기능 4: 다음 달 일정·지출 예측 ----------

class RecurringPattern(BaseModel):
    category: str
    merchant: str | None
    cadence: str         # monthly | biweekly | weekly
    typical_day: int
    avg_amount: int
    occurrences: int
    confidence: float


class PredictedEvent(BaseModel):
    title: str
    category: str
    day: int
    amount: int
    confidence: float
    reason: str


class ForecastResult(BaseModel):
    month_label: str
    predicted_events: list[PredictedEvent]
    predicted_total: int
    by_category: dict[str, int]
    disposable_month: int
    over_budget_by: int          # 0이면 예산 내
    verdict: str                 # 사용자에게 보여줄 한 줄
    patterns: list[RecurringPattern]
