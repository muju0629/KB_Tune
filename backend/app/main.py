"""KB Tune 에이전트 API.

계층: 요청 → (결정론적)엔진 → PlanResult → LLM(설명·판단) → groundedness 검증 → 응답.
LLM 키가 없어도 모든 엔드포인트가 동작한다(엔진 + 템플릿).
"""
from __future__ import annotations

from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse

from . import baseline, config
from .config import llm_enabled
from .data import DAYS_IN_MONTH, PROFILE, TRANSACTIONS_HISTORY
from .engine import build_plan
from .engine.budget import disposable_month
from .engine.categorize import categorize_many
from .engine.estimate import estimate_event_cost
from .engine.forecast import forecast_next_month
from .eval.runner import run_eval
from .llm.agent import run_agent
from .llm.chat import chat_stream
from .llm.coach import coach
from .llm.extract import extract_from_text
from .llm.search import search_cost
from .models import (AgentRequest, AgentResult, CategorizeRequest,
                     CategorizeResult, ChatRequest,
                     CoachRequest, EstimateRequest, EstimateResult,
                     ExtractRequest, ExtractResult, ForecastResult,
                     PlanRequest, PlanResult, Profile, SearchCostRequest,
                     SearchCostResult, SearchRequest)
from . import websearch
from .security import BodySizeLimitMiddleware, rate_limit, require_api_key

app = FastAPI(title="KB Tune Agent", version="1.0.0")

app.add_middleware(BodySizeLimitMiddleware)

# 네이티브 앱은 CORS를 안 따지므로 기본값은 '아무 오리진도 허용 안 함'이다.
# 웹 데모를 붙일 때만 KB_TUNE_ALLOWED_ORIGINS 에 해당 오리진을 적는다.
app.add_middleware(
    CORSMiddleware,
    allow_origins=config.ALLOWED_ORIGINS,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type", "X-API-Key"],
)

# 모든 엔드포인트에 붙는 인증. 속도 제한은 비용이 다르므로 엔드포인트마다 따로 건다.
_auth = [Depends(require_api_key)]
_llm = _auth + [Depends(rate_limit("llm"))]
_cheap = _auth + [Depends(rate_limit("cheap"))]


def _profile(req: PlanRequest) -> Profile:
    """요청에 프로필이 없으면 데모 페르소나. 고정비가 비면 데모 고정비로 채움."""
    if req.profile is None:
        return PROFILE
    p = req.profile
    if not p.fixed_costs:
        p = p.model_copy(update={"fixed_costs": PROFILE.fixed_costs})
    return p


# 헬스체크는 인증 없이 열어둔다 — 외부 모니터가 키 없이 확인할 수 있어야 하고,
# 노출하는 값도 상태와 LLM 사용 여부뿐이다. 속도 제한은 건다.
@app.get("/api/health", dependencies=[Depends(rate_limit("cheap"))])
def health():
    backend = config.llm_backend()
    return {
        "status": "ok",
        "llm_enabled": llm_enabled(),
        "llm_backend": backend,
        "external_llm": config.llm_is_external(backend),
    }


@app.post("/api/plan", response_model=PlanResult, dependencies=_cheap)
def plan(req: PlanRequest):
    """순수 엔진 결과(숫자). LLM 미사용 — 알고리즘 단독으로 동작함을 보여줌."""
    return build_plan(_profile(req), req.today, req.include_candidate)


@app.post("/api/coach", dependencies=_llm)
def coach_endpoint(req: CoachRequest):
    """엔진 계획 + 접지된 LLM 코칭(키 없으면 템플릿)."""
    p = build_plan(_profile(req), req.today, req.include_candidate)
    return {"plan": p, "coach": coach(p)}


@app.post("/api/chat", dependencies=_llm)
def chat_endpoint(req: ChatRequest):
    """계획을 바꾸는 대화 — 텍스트 스트리밍."""
    p = build_plan(_profile(req), req.today, req.include_candidate)
    return StreamingResponse(
        chat_stream(p, req.message, req.card, req.upcoming, req.app_numbers,
                    req.history, req.past),
        media_type="text/plain; charset=utf-8",
    )


@app.post("/api/search", dependencies=_llm)
def search_endpoint(req: SearchRequest):
    """웹 검색 — 앱 데이터로 답할 수 없는 질문만 온다.

    받는 것은 질문 한 줄뿐이다. 계획·카드·일정은 이 경로에 실리지 않는다.
    키가 없으면 검색을 켜지 않았다고 분명히 답한다.
    """
    if not websearch.enabled():
        return {
            "answer": "검색은 아직 켜져 있지 않아요. 지금은 성제님의 일정과 소비로 답할 수 있는 것만 도와드릴게요.",
            "sources": [],
        }
    result = websearch.search(req.query)
    if not result["answer"]:
        return {"answer": "검색해 봤는데 마땅한 결과가 없었어요.", "sources": []}
    return result


@app.get("/api/eval", dependencies=_auth + [Depends(rate_limit("eval"))])
def eval_endpoint():
    """평가 리포트 — 엔진 골든 테스트 + LLM groundedness."""
    return run_eval()


# ---------- AI 기능 ① 일정 → 예상 지출 ----------

@app.post("/api/estimate", response_model=EstimateResult, dependencies=_llm)
def estimate_endpoint(req: EstimateRequest):
    """일정 제목만으로 예상 지출을 추정(캘린더의 같은 유형 + 엔진 범위 보정)."""
    # 제목은 규칙 사전으로도 가치를 낼 수 있는 반면 실명·약속 내용을 포함할
    # 수 있다. 외부 모델에는 아예 보내지 않고, 루프백 로컬 모델만 선택적으로 쓴다.
    use_private_llm = config.llm_enabled() and not config.llm_is_external()
    return estimate_event_cost(req.title, TRANSACTIONS_HISTORY,
                               use_llm=use_private_llm, age_bucket=req.age_bucket)


# ---------- 대화 에이전트 ----------

@app.post("/api/agent", response_model=AgentResult, dependencies=_llm)
def agent_endpoint(req: AgentRequest):
    """대화 한 턴 — 답변 + 앱이 실행할 동작 제안.

    message 는 앱이 기기에서 가명처리한 문장이다(이름·연락처·저장된 일정 제목 마스킹).
    서버는 그걸 되돌릴 수 없고, 저장하지도 않는다.

    동작은 제안일 뿐이다. 실행은 앱이 하고, 사용자가 버튼을 눌러야 일어난다 —
    서버에는 애초에 그 사용자의 캘린더가 없다.
    """
    plan = build_plan(_profile(req), req.today, req.include_candidate)
    return run_agent(plan, req.message, req.today, req.may_search,
                     req.history, req.events)


# ---------- 웹 검색으로 금액 찾기 ----------

@app.post("/api/search/cost", response_model=SearchCostResult, dependencies=_llm)
def search_cost_endpoint(req: SearchCostRequest):
    """검색어 하나로 1인 기준 금액을 찾는다. 사용자가 켰을 때만 앱이 부른다.

    이 통로는 질의가 모델 제공자를 거쳐 검색 엔진까지 나간다. 그래서 SearchRequest 에는
    검색어 말고 아무 필드도 없고, 앱은 코드에 정의된 말로만 조립해서 보낸다
    (`SearchQuery.make()`). 일정 제목 원문은 여기 도달할 경로가 없다.
    """
    return search_cost(req.query)


# ---------- 공개 통계 기준 금액 ----------

@app.get("/api/baseline", dependencies=_cheap)
def baseline_endpoint():
    """공개 통계 기준 금액 표 전체.

    앱은 이걸 통째로 받아 기기에 캐시하고 조회는 기기 안에서 한다. 일정 제목을
    서버로 보내지 않기 위해서다 — 제목당 한 번 물어보는 방식이면 제목이 나간다.
    표에는 공개 통계만 있어서 응답에 개인 정보가 없다.
    """
    return baseline.table()


# ---------- AI 기능 ② 캡처 → 거래 추출 ----------

@app.post("/api/extract", response_model=ExtractResult, dependencies=_llm)
def extract_endpoint(req: ExtractRequest):
    """text=기기 OCR 결과. image_base64 원본은 개인정보 보호를 위해 거절한다."""
    if req.text:
        return extract_from_text(req.text)
    if req.image_base64:
        # 금융 캡처 원본에는 이름·계좌·잔액이 한 화면에 섞인다. 서버에서 완전한
        # 비식별화를 보장할 수 없으므로 외부 비전 모델로 보내지 않는다.
        raise HTTPException(
            status_code=422,
            detail="개인정보 보호를 위해 원본 이미지는 외부 AI로 보내지 않아요. 기기에서 OCR한 텍스트를 보내 주세요.",
        )
    return ExtractResult(transactions=[], total=0, method="none",
                         warnings=["text 또는 image_base64 중 하나가 필요해요."])


# ---------- AI 기능 ③ 가맹점 → 카테고리 ----------

@app.post("/api/categorize", response_model=CategorizeResult, dependencies=_llm)
def categorize_endpoint(req: CategorizeRequest):
    """규칙 사전 우선 → 놓친 것만 LLM(키 있을 때). 카테고리 집합은 엔진이 강제."""
    # 가맹점 원문은 행동반경·주소를 노출할 수 있어 외부 LLM 전송 금지.
    use_private_llm = config.llm_enabled() and not config.llm_is_external()
    results, hit = categorize_many(req.merchants, use_llm=use_private_llm)
    return CategorizeResult(results=results, rule_hit_rate=hit)


# ---------- AI 기능 ④ 다음 달 예측 ----------

@app.post("/api/forecast", response_model=ForecastResult, dependencies=_cheap)
def forecast_endpoint(req: PlanRequest):
    """7월 캘린더에서 반복 패턴을 찾아 다음 달 일정·지출을 예측."""
    p = _profile(req)
    return forecast_next_month(TRANSACTIONS_HISTORY, disposable_month(p))
