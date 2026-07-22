"""요청/응답 스키마. 엔진 출력(결정론적 숫자)과 LLM 출력(언어)을 명확히 분리한다."""
from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field

Direction = Literal["reduce", "maintain", "increase"]


# ---------- 입력 ----------

class FixedCost(BaseModel):
    name: str
    amount: int


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
    name: str = "성제"
    role: str = "대학생 · 인포스탁 인턴"
    age: int | None = None
    monthly_income: int = 2_200_000
    savings_goal: int = 800_000
    fixed_costs: list[FixedCost] = Field(default_factory=list)
    direction: Direction = "maintain"
    protected_categories: list[str] = Field(default_factory=list)


class PlanRequest(BaseModel):
    """미지정 시 데모 페르소나 사용. 일부 필드만 덮어쓸 수 있음."""
    profile: Optional[Profile] = None
    today: int = 22  # 2026년 7월 캘린더 기준일
    include_candidate: bool = False  # 위험 후보 일정을 계획에 반영할지


class CoachRequest(PlanRequest):
    pass


class ChatRequest(PlanRequest):
    message: str


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


# ---------- LLM 출력(언어) ----------

class CoachResponse(BaseModel):
    direction: Direction
    headline: str        # 결론 한 줄
    reason: str          # 이유(반영한 데이터)
    impact: str          # 영향(전/후)
    recommendation: str  # 다음 행동 제안
    grounded: bool = True
    used_llm: bool = True


class EvalResult(BaseModel):
    engine_tests_passed: int
    engine_tests_total: int
    groundedness_rate: float
    details: list[str]


# ---------- AI 기능 1: 일정 → 예상 지출 추정 ----------

class EstimateRequest(BaseModel):
    title: str
    day: int | None = None


class EstimateResult(BaseModel):
    title: str
    category: str
    amount: int          # 예상 지출(엔진이 최종 검증·보정한 값)
    low: int             # 같은 일정 유형의 예상 하한
    high: int            # 같은 일정 유형의 예상 상한
    confidence: float    # 0~1
    basis: str           # 사용자에게 보여줄 근거 한 줄
    method: str          # rule | history | llm
    llm_raw: int | None = None   # LLM 원안(엔진 보정 전) — 투명성


# ---------- AI 기능 2: 캡처 이미지 → 거래 추출 ----------

class ExtractRequest(BaseModel):
    text: str | None = None          # iOS Vision(온디바이스 OCR) 결과
    image_base64: str | None = None  # 이미지 직접 전달(LLM 비전, 키 필요)


class ExtractedTransaction(BaseModel):
    merchant: str
    amount: int
    category: str
    confidence: float


class ExtractResult(BaseModel):
    transactions: list[ExtractedTransaction]
    total: int
    method: str          # ocr-rule | llm-vision | llm-text
    warnings: list[str] = Field(default_factory=list)


# ---------- AI 기능 3: 거래 → 카테고리 자동 분류 ----------

class CategorizeRequest(BaseModel):
    merchants: list[str]


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
