"""KB Tune 에이전트 API.

계층: 요청 → (결정론적)엔진 → PlanResult → LLM(설명·판단) → groundedness 검증 → 응답.
LLM 키가 없어도 모든 엔드포인트가 동작한다(엔진 + 템플릿).
"""
from __future__ import annotations

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse

from . import config
from .config import llm_enabled
from .data import DAYS_IN_MONTH, PROFILE, TRANSACTIONS_HISTORY
from .engine import build_plan
from .engine.budget import disposable_month
from .engine.categorize import categorize_many
from .engine.estimate import estimate_event_cost
from .engine.forecast import forecast_next_month
from .eval.runner import run_eval
from .llm.chat import chat_stream
from .llm.coach import coach
from .llm.extract import extract_from_image, extract_from_text
from .models import (CategorizeRequest, CategorizeResult, ChatRequest,
                     CoachRequest, EstimateRequest, EstimateResult,
                     ExtractRequest, ExtractResult, ForecastResult,
                     PlanRequest, PlanResult, Profile)

app = FastAPI(title="KB Tune Agent", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_methods=["*"], allow_headers=["*"],
)


def _profile(req: PlanRequest) -> Profile:
    """요청에 프로필이 없으면 데모 페르소나. 고정비가 비면 데모 고정비로 채움."""
    if req.profile is None:
        return PROFILE
    p = req.profile
    if not p.fixed_costs:
        p = p.model_copy(update={"fixed_costs": PROFILE.fixed_costs})
    return p


@app.get("/api/health")
def health():
    return {"status": "ok", "llm_enabled": llm_enabled()}


@app.post("/api/plan", response_model=PlanResult)
def plan(req: PlanRequest):
    """순수 엔진 결과(숫자). LLM 미사용 — 알고리즘 단독으로 동작함을 보여줌."""
    return build_plan(_profile(req), req.today, req.include_candidate)


@app.post("/api/coach")
def coach_endpoint(req: CoachRequest):
    """엔진 계획 + 접지된 LLM 코칭(키 없으면 템플릿)."""
    p = build_plan(_profile(req), req.today, req.include_candidate)
    return {"plan": p, "coach": coach(p)}


@app.post("/api/chat")
def chat_endpoint(req: ChatRequest):
    """계획을 바꾸는 대화 — 텍스트 스트리밍."""
    p = build_plan(_profile(req), req.today, req.include_candidate)
    return StreamingResponse(
        chat_stream(p, req.message, req.card, req.upcoming, req.app_numbers),
        media_type="text/plain; charset=utf-8",
    )


@app.get("/api/eval")
def eval_endpoint():
    """평가 리포트 — 엔진 골든 테스트 + LLM groundedness."""
    return run_eval()


# ---------- AI 기능 ① 일정 → 예상 지출 ----------

@app.post("/api/estimate", response_model=EstimateResult)
def estimate_endpoint(req: EstimateRequest):
    """일정 제목만으로 예상 지출을 추정(캘린더의 같은 유형 + 엔진 범위 보정)."""
    return estimate_event_cost(req.title, TRANSACTIONS_HISTORY,
                               use_llm=config.llm_backend() == "claude")


# ---------- AI 기능 ② 캡처 → 거래 추출 ----------

@app.post("/api/extract", response_model=ExtractResult)
def extract_endpoint(req: ExtractRequest):
    """text=기기 OCR 결과(키 불필요) 또는 image_base64=이미지 직접(Claude 비전)."""
    if req.text:
        return extract_from_text(req.text)
    if req.image_base64:
        return extract_from_image(req.image_base64)
    return ExtractResult(transactions=[], total=0, method="none",
                         warnings=["text 또는 image_base64 중 하나가 필요해요."])


# ---------- AI 기능 ③ 가맹점 → 카테고리 ----------

@app.post("/api/categorize", response_model=CategorizeResult)
def categorize_endpoint(req: CategorizeRequest):
    """규칙 사전 우선 → 놓친 것만 LLM(키 있을 때). 카테고리 집합은 엔진이 강제."""
    results, hit = categorize_many(req.merchants, use_llm=config.llm_backend() == "claude")
    return CategorizeResult(results=results, rule_hit_rate=hit)


# ---------- AI 기능 ④ 다음 달 예측 ----------

@app.post("/api/forecast", response_model=ForecastResult)
def forecast_endpoint(req: PlanRequest):
    """7월 캘린더에서 반복 패턴을 찾아 다음 달 일정·지출을 예측."""
    p = _profile(req)
    return forecast_next_month(TRANSACTIONS_HISTORY, disposable_month(p))
