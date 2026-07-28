"""AI 기능 ② — 캡처 이미지 → 거래 추출.

허용 경로:
  text: iOS Vision(온디바이스 OCR, 무료·오프라인)이 뽑은 텍스트 → 규칙 파서로 구조화

원본 금융 캡처에는 실명·계좌·잔액이 섞일 수 있어 image_base64 경로는 외부로
전송하지 않는다. 카테고리는 엔진의 분류기가 붙이고, 금액은 정수로 검증한다.
"""
from __future__ import annotations

import re

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
    """원본 금융 캡처는 외부 모델로 보내지 않는다.

    이미지에는 실명·계좌·잔액이 함께 찍힐 수 있어 서버에서 완전 비식별화할 수 없다.
    따라서 앱의 Apple Vision으로 OCR한 텍스트만 받아 결정론 파서로 처리한다.
    """
    return ExtractResult(
        transactions=[], total=0, method="on-device-required",
        warnings=["개인정보 보호를 위해 원본 이미지는 외부 AI로 보내지 않아요. 기기에서 OCR한 텍스트를 보내 주세요."],
    )
