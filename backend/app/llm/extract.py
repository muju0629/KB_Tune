"""AI 기능 ② — 캡처 이미지 → 거래 추출.

두 경로:
  A) text  : iOS Vision(온디바이스 OCR, 무료·오프라인)이 뽑은 텍스트 → 규칙 파서로 구조화
  B) image : Claude 비전이 이미지에서 직접 구조화 (키 필요)
어느 쪽이든 **카테고리는 엔진의 분류기**가 붙이고, 금액은 정수로 검증한다.
"""
from __future__ import annotations

import re

from .. import config
from ..engine.categorize import categorize_rule
from ..models import ExtractedTransaction, ExtractResult

# "스타벅스 강남R점  5,600원" / "-5,600" / "5,600원 스타벅스"
AMOUNT_RE = re.compile(r"[-−]?\s*(\d{1,3}(?:,\d{3})+|\d{4,7})\s*원?")
NOISE = ("잔액", "합계", "총액", "누적", "포인트", "적립", "한도", "이월", "출금가능")


def _clean_merchant(s: str) -> str:
    s = AMOUNT_RE.sub("", s)
    s = re.sub(r"[0-9:./\-–—|()\[\]]+", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s[:30]


def extract_from_text(text: str) -> ExtractResult:
    """OCR 텍스트 → 거래 목록(결정론). 키 불필요."""
    txns: list[ExtractedTransaction] = []
    warnings: list[str] = []

    for raw in text.splitlines():
        line = raw.strip()
        if not line or any(n in line for n in NOISE):
            continue
        m = AMOUNT_RE.search(line)
        if not m:
            continue
        amount = int(m.group(1).replace(",", ""))
        if amount < 500 or amount > 3_000_000:   # 잔액·전화번호 등 오검출 차단
            continue
        merchant = _clean_merchant(line)
        if len(merchant) < 2:
            continue
        cat, conf = categorize_rule(merchant)
        txns.append(ExtractedTransaction(
            merchant=merchant, amount=amount,
            category=cat or "기타", confidence=conf if cat else 0.35,
        ))

    if not txns:
        warnings.append("금액으로 인식되는 줄을 찾지 못했어요. 캡처 화질이나 범위를 확인해 주세요.")

    return ExtractResult(transactions=txns, total=sum(t.amount for t in txns),
                         method="ocr-rule", warnings=warnings)


def extract_from_image(image_base64: str, media_type: str = "image/jpeg") -> ExtractResult:
    """Claude 비전으로 이미지에서 직접 구조화. 키 없거나 실패하면 빈 결과 + 안내."""
    if config.llm_backend() != "claude":
        return ExtractResult(
            transactions=[], total=0, method="llm-vision",
            warnings=["이미지 직접 분석은 Claude 키가 필요해요. 기기 OCR 텍스트를 보내면 키 없이도 추출됩니다."],
        )
    try:
        import json

        import anthropic
        client = anthropic.Anthropic()
        prompt = (
            "이 금융 앱 캡처에서 개별 거래만 뽑아줘. 잔액·합계·포인트는 제외.\n"
            'JSON 배열만 출력: [{"merchant":"가맹점","amount":정수원}]'
        )
        r = client.messages.create(
            model=config.CLAUDE_MODEL, max_tokens=1024,
            messages=[{"role": "user", "content": [
                {"type": "image", "source": {"type": "base64",
                                             "media_type": media_type, "data": image_base64}},
                {"type": "text", "text": prompt},
            ]}],
        )
        text = "".join(b.text for b in r.content if b.type == "text")
        s, e = text.find("["), text.rfind("]")
        rows = json.loads(text[s:e + 1]) if s >= 0 else []
    except Exception:
        return ExtractResult(transactions=[], total=0, method="llm-vision",
                             warnings=["이미지 분석에 실패했어요. 다시 시도해 주세요."])

    txns: list[ExtractedTransaction] = []
    for row in rows:
        try:
            amount = int(row["amount"])
            merchant = str(row["merchant"])[:30]
        except Exception:
            continue
        if not (500 <= amount <= 3_000_000):
            continue
        cat, conf = categorize_rule(merchant)   # 카테고리는 엔진이 판정
        txns.append(ExtractedTransaction(merchant=merchant, amount=amount,
                                         category=cat or "기타",
                                         confidence=conf if cat else 0.4))

    return ExtractResult(transactions=txns, total=sum(t.amount for t in txns),
                         method="llm-vision", warnings=[])
