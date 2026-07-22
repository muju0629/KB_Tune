"""AI 기능 ③ — 가맹점명 → 카테고리 자동 분류.

실제 가맹점명은 지저분("스타벅스 강남R점", "(주)우아한형제들")해서 규칙만으로는 한계가 있다.
1차: 결정론 규칙 사전(키 불필요, 즉시·무료) → 2차: 규칙 미스만 LLM으로 분류(선택).
LLM 결과도 허용 카테고리 집합으로 강제 검증한다(엔진이 최종 판정).
"""
from __future__ import annotations

from ..models import CategoryGuess

# 허용 카테고리(엔진 계약). LLM이 이 밖의 값을 내면 폐기한다.
CATEGORIES = [
    "출근", "업무·학업", "데이트", "가족", "모임", "문화", "자기관리",
    "카페", "외식", "배달", "쇼핑", "교통", "구독", "여가", "경조사", "기타",
]

RULES: dict[str, list[str]] = {
    "출근": ["인포스탁", "출근", "인턴"],
    "업무·학업": ["SensCoreAI", "연구", "스터디", "자습", "회의", "SOL TA"],
    "데이트": ["데이트", "기념일", "200일"],
    "가족": ["가족", "부모님"],
    "모임": ["친구", "뒤풀이", "회식"],
    "문화": ["미술관", "무대인사", "오디움"],
    "자기관리": ["한의원", "병원", "제모", "미용"],
    "카페": ["스타벅스", "스벅", "투썸", "이디야", "메가커피", "메가", "빽다방", "할리스",
             "커피", "카페", "공차", "컴포즈", "파스쿠찌", "탐앤탐스"],
    "배달": ["배달의민족", "배민", "요기요", "쿠팡이츠", "배달"],
    "술·모임": ["포차", "이자카야", "호프", "술집", "주점", "맥주", "소주", "펍", "와인",
                "회식", "모임"],
    "외식": ["김밥", "한솥", "맘스터치", "본죽", "식당", "치킨", "피자", "버거", "맥도날드",
             "롯데리아", "분식", "국밥", "돈까스", "샐러드", "쌀국수", "마라", "떡볶이", "초밥"],
    "쇼핑": ["올리브영", "다이소", "무신사", "쿠팡", "지마켓", "11번가", "백화점", "이마트",
             "홈플러스", "GS25", "CU", "세븐일레븐", "편의점", "마트", "에이블리"],
    "교통": ["티머니", "카카오ت", "카카오T", "택시", "지하철", "버스", "코레일", "SRT",
             "주유", "고속", "대중교통"],
    "구독": ["넷플릭스", "유튜브", "스포티파이", "왓챠", "티빙", "웨이브", "쿠팡플레이",
             "멤버십", "구독", "애플"],
    "여가": ["CGV", "메가박스", "롯데시네마", "영화", "PC방", "노래방", "볼링", "전시",
             "공연", "콘서트", "헬스", "짐"],
    "경조사": ["축의", "부의", "결혼", "돌잔치", "장례", "화환"],
}


def categorize_rule(merchant: str) -> tuple[str | None, float]:
    """규칙 기반 분류. (카테고리, 신뢰도) — 미스면 (None, 0)."""
    name = merchant.replace(" ", "").lower()
    for cat, keys in RULES.items():
        for k in keys:
            if k.replace(" ", "").lower() in name:
                return cat, 0.95
    return None, 0.0


def categorize_many(merchants: list[str], use_llm: bool = False) -> tuple[list[CategoryGuess], float]:
    """규칙 우선 → 미스만 LLM(선택). 반환: (결과, 규칙 적중률)"""
    results: list[CategoryGuess] = []
    misses: list[str] = []

    for m in merchants:
        cat, conf = categorize_rule(m)
        if cat:
            results.append(CategoryGuess(merchant=m, category=cat, confidence=conf, method="rule"))
        else:
            misses.append(m)
            results.append(CategoryGuess(merchant=m, category="기타", confidence=0.3, method="fallback"))

    hit_rate = round((len(merchants) - len(misses)) / len(merchants), 3) if merchants else 1.0

    if use_llm and misses:
        guessed = _llm_categorize(misses)
        by_merchant = {g["merchant"]: g["category"] for g in guessed}
        for r in results:
            if r.method == "fallback" and r.merchant in by_merchant:
                cat = by_merchant[r.merchant]
                if cat in CATEGORIES:          # 엔진이 계약 위반 값을 차단
                    r.category = cat
                    r.confidence = 0.75
                    r.method = "llm"

    return results, hit_rate


def _llm_categorize(merchants: list[str]) -> list[dict]:
    """규칙이 놓친 가맹점만 LLM으로 분류. 실패하면 빈 리스트(폴백 유지)."""
    from .. import config
    if config.llm_backend() != "claude":
        return []
    try:
        import json

        import anthropic
        client = anthropic.Anthropic()
        allowed = ", ".join(CATEGORIES)
        prompt = (
            f"다음 가맹점명을 카테고리로 분류해줘. 카테고리는 반드시 [{allowed}] 중 하나.\n"
            f'JSON 배열만 출력: [{{"merchant":"...","category":"..."}}]\n\n'
            + "\n".join(f"- {m}" for m in merchants)
        )
        r = client.messages.create(
            model=config.CLAUDE_MODEL, max_tokens=512,
            messages=[{"role": "user", "content": prompt}],
        )
        text = "".join(b.text for b in r.content if b.type == "text")
        start, end = text.find("["), text.rfind("]")
        return json.loads(text[start:end + 1]) if start >= 0 else []
    except Exception:
        return []
