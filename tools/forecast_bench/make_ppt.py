"""발표용 pptx 생성. results/results.csv 와 fig/*.png 를 읽어 조립한다.

    python make_ppt.py   → results/KB_Tune_예측모델.pptx

16:9, 앱 디자인 토큰(#FBFAF7 캔버스 / #25241F ink / #FFCC00 accent) 사용.
차트 색은 make_figures.py 가 dataviz 검증기를 통과한 조합으로 이미 그려 놨다.
"""
from __future__ import annotations

from pathlib import Path

import pandas as pd
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN
from pptx.util import Emu, Inches, Pt

HERE = Path(__file__).parent
RES = HERE / "results"
FIG = RES / "fig"

CANVAS = RGBColor(0xFB, 0xFA, 0xF7)
INK = RGBColor(0x25, 0x24, 0x1F)
INK2 = RGBColor(0x52, 0x51, 0x4E)
MUTED = RGBColor(0x89, 0x87, 0x81)
ACCENT = RGBColor(0xED, 0xA1, 0x00)
RED = RGBColor(0xD0, 0x3B, 0x3B)
BLUE = RGBColor(0x2A, 0x78, 0xD6)
FONT = "Apple SD Gothic Neo"

W, H = Inches(13.333), Inches(7.5)


def blank(prs):
    s = prs.slides.add_slide(prs.slide_layouts[6])
    bg = s.background.fill
    bg.solid()
    bg.fore_color.rgb = CANVAS
    return s


def text(slide, txt, x, y, w, h, size=18, color=INK, bold=False,
         align=PP_ALIGN.LEFT, space_after=6):
    box = slide.shapes.add_textbox(x, y, w, h)
    tf = box.text_frame
    tf.word_wrap = True
    for i, line in enumerate(txt.split("\n")):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align
        p.space_after = Pt(space_after)
        run = p.add_run()
        run.text = line
        run.font.size = Pt(size)
        run.font.bold = bold
        run.font.name = FONT
        run.font.color.rgb = color
    return box


def title(slide, head, sub=None):
    text(slide, head, Inches(0.7), Inches(0.45), Inches(12), Inches(0.9),
         size=32, bold=True)
    if sub:
        text(slide, sub, Inches(0.7), Inches(1.32), Inches(12), Inches(0.6),
             size=15, color=MUTED)


def rule(slide, y):
    ln = slide.shapes.add_shape(1, Inches(0.7), y, Inches(11.9), Emu(9525 * 2))
    ln.fill.solid()
    ln.fill.fore_color.rgb = ACCENT
    ln.line.fill.background()
    ln.shadow.inherit = False


def picture(slide, name, x, y, w=None, h=None):
    p = FIG / name
    if not p.exists():
        return None
    return slide.shapes.add_picture(str(p), x, y, width=w, height=h)


def table(slide, rows, x, y, w, h, col_w=None, size=11, header_bold=True,
          highlight=()):
    n_r, n_c = len(rows), len(rows[0])
    shape = slide.shapes.add_table(n_r, n_c, x, y, w, h)
    tbl = shape.table
    if col_w:
        for i, cw in enumerate(col_w):
            tbl.columns[i].width = cw
    for r, row in enumerate(rows):
        for c, val in enumerate(row):
            cell = tbl.cell(r, c)
            cell.text = ""
            para = cell.text_frame.paragraphs[0]
            para.alignment = PP_ALIGN.LEFT if c == 0 else PP_ALIGN.RIGHT
            run = para.add_run()
            run.text = str(val)
            run.font.size = Pt(size)
            run.font.name = FONT
            is_head = r == 0
            run.font.bold = (is_head and header_bold) or (r in highlight)
            run.font.color.rgb = INK if is_head or r in highlight else INK2
            cell.fill.solid()
            cell.fill.fore_color.rgb = CANVAS
            cell.margin_left = Inches(0.08)
            cell.margin_right = Inches(0.08)
            cell.margin_top = Inches(0.02)
            cell.margin_bottom = Inches(0.02)
    return tbl


# ── 슬라이드 ────────────────────────────────────────────────────────────────
def s_cover(prs):
    s = blank(prs)
    text(s, "소비 예측 모델", Inches(0.9), Inches(2.2), Inches(11), Inches(1.1),
         size=48, bold=True)
    text(s, "규칙 + 과거 평균  →  계층 베이지안 marked renewal process",
         Inches(0.9), Inches(3.35), Inches(11), Inches(0.6), size=20, color=INK2)
    rule(s, Inches(4.15))
    text(s, "14종 모델 비교 · AI Hub 카드 승인매출 5,000명 · 온디바이스 실행 제약",
         Inches(0.9), Inches(4.45), Inches(11), Inches(0.5), size=15, color=MUTED)
    return s


def s_problem(prs):
    s = blank(prs)
    title(s, "기존 구현은 세 문제를 하나로 묶었다",
          "서로 다른 확률 구조 — 하나의 규칙으로는 각각의 오차 특성을 표현할 수 없다")
    rows = [["대상", "통계적 성질", "기존 처리"],
            ["일정 단건 금액", "우편향 연속 확률변수", "키워드 규칙 + 개인 이력 산술평균"],
            ["반복 소비 발생 시점", "간헐 시계열 / 갱신 과정", "없음"],
            ["주간 총 지출", "위 둘의 복합 합", "남은예산 ÷ 남은주수 (배분 산수)"],
            ["목표 달성 확률", "총액 분포의 누적확률", "정규근사, σ = 100,000 고정"]]
    table(s, rows, Inches(0.7), Inches(2.3), Inches(11.9), Inches(2.6),
          col_w=[Inches(2.7), Inches(3.6), Inches(5.6)], size=14)
    text(s, "→ 특히 구간(불확실성)을 정직하게 낼 수 없다",
         Inches(0.7), Inches(5.3), Inches(11), Inches(0.5), size=18, bold=True, color=ACCENT)
    return s


def s_data(prs):
    s = blank(prs)
    title(s, "사용 데이터", "AI Hub 117 금융 합성데이터 — 03.카드 승인매출정보")
    rows = [["항목", "값"],
            ["원본 규모", "300만 회원 × 6개월 = 1,800만 행 × 430 컬럼"],
            ["압축 / 해제", "4.7GB / 22.3GB   (디스크 여유 13GB → 풀지 않고 스트림)"],
            ["관측 단위", "회원 × 월 집계 — 거래 단위 레코드 없음 (12개 zip 전수 조사)"],
            ["표본", "체계추출 5,000명 (회원번호 600 간격) → 30,000 행"],
            ["기간", "2018-07 ~ 2018-12"],
            ["타깃", "이용금액_신용_B0M + 이용금액_체크_B0M"],
            ["타깃 분포", "0원 26.8% · 중앙값 297,868원 · 우편향"],
            ["추가 디스크", "0바이트 — zip 스트림에서 430컬럼 중 18개만 읽음"]]
    table(s, rows, Inches(0.7), Inches(2.2), Inches(11.9), Inches(3.0),
          col_w=[Inches(2.6), Inches(9.3)], size=13)
    text(s, "전처리 2건 · 순환불 달(4.0%)을 0원 클리핑 · 전 모델에 앱의 CLAMP_MULTIPLIER=2.5 동일 적용",
         Inches(0.7), Inches(5.5), Inches(11.9), Inches(0.5), size=13, color=MUTED)
    return s


def s_autocorr(prs):
    s = blank(prs)
    title(s, "이 데이터의 결정적 성질",
          "직전 달이 다음 달의 95.8%를 설명한다 — 벤치마크가 모델을 구분하기 어렵다")
    picture(s, "6_autocorr.png", Inches(0.8), Inches(2.05), h=Inches(4.9))
    x = Inches(7.4)
    text(s, "R² = 0.958", x, Inches(2.3), Inches(5.2), Inches(0.8),
         size=34, bold=True, color=ACCENT)
    text(s, "건수 자기상관 0.989\n개인 간 분산 0.760\n개인 내 분산 0.159  (4.8배 차)",
         x, Inches(3.2), Inches(5.2), Inches(1.4), size=15, color=INK2)
    text(s, "횡단면 WAPE 는 “고소비자를 고소비자로\n맞히는 능력”에 지배된다.\n"
            "그것은 예측이 아니라 수준 기억이다.\n\n"
            "→ 변화량 기준 지표를 병기했다",
         x, Inches(4.7), Inches(5.2), Inches(2.0), size=14, color=INK)
    return s


def s_model(prs):
    s = blank(prs)
    title(s, "모델 — 금액과 주기를 한 구조로",
          "Marked renewal process · 켤레 사후분포라 온디바이스에서 닫힌 형태로 갱신된다")
    body = (
        "빈도    N(Δ) ~ Poisson(λΔ),        λ ~ Gamma(a, b)          ← 개인이 학습\n"
        "금액    log x ~ Normal(μ, σ²),      μ ~ Normal(μ₀, τ²)       ← 개인이 학습\n"
        "간격    T ~ Weibull(k, η),          η = 1 / (λ·Γ(1+1/k))     ← 규칙성"
    )
    text(s, body, Inches(0.8), Inches(2.25), Inches(11.6), Inches(1.6),
         size=15, color=INK)
    text(s, "η 를 위와 같이 두면 형태 k 를 바꿔도 평균 간격이 1/λ 로 보존된다 — 규칙성과 빈도가 직교한다.",
         Inches(0.8), Inches(3.75), Inches(11.6), Inches(0.5), size=13, color=MUTED)

    rows = [["요구", "이 구조가 만족시키는 방식"],
            ["금액과 주기를 한 모델로", "같은 사후분포에서 “언제”와 “얼마”가 함께 나온다"],
            ["주간 총액이 파생되어야", "S(Δ) = Σ xᵢ — 세 번째 모델이 불필요"],
            ["온디바이스 실행", "켤레라서 갱신이 닫힌 형태. 부동소수 덧셈 몇 번"],
            ["서버 없는 온라인 학습", "충분통계량만 저장. 원자료·전송 불필요"],
            ["콜드스타트", "관측 0건이면 사후분포 = 사전분포. 분기 처리 없음"],
            ["설명 가능", "“보통 12일마다, 오늘 14일째” 가 모델 항에서 직접 나온다"]]
    table(s, rows, Inches(0.8), Inches(4.3), Inches(11.6), Inches(2.5),
          col_w=[Inches(3.5), Inches(8.1)], size=13)
    return s


def s_math(prs):
    s = blank(prs)
    title(s, "사용하면서 모델이 바뀌는 방식 — 닫힌 형태",
          "충분통계량 4개만 폰에 저장한다: n_tx, D, Σlog x, n_amt")
    body = (
        "발생률       E[λ | D]  =  (a + n_tx) / (b + D)\n\n"
        "금액         μ_post  =  ( μ₀/τ² + Σlog x /σ² ) / ( 1/τ² + n_amt/σ² )\n\n"
        "불확실성     Var(log x | D)  =  ( 1/τ² + n_amt/σ² )⁻¹   +   σ²\n"
        "                                모수 불확실성 ↓          개인 내 변동 (남는다)\n\n"
        "감쇠         n ← γn + Δn,   D ← γD + ΔD        유효 기억 1/(1−γ) 관측\n\n"
        "규칙성       CV(T) = √( Γ(1+2/k) / Γ(1+1/k)² − 1 )   →   k 를 역산"
    )
    text(s, body, Inches(0.8), Inches(2.15), Inches(11.7), Inches(3.9),
         size=15, color=INK, space_after=2)
    text(s, "μ_post 는 신용도 가중 w = n/(n+k) 의 정확한 형태다 — 계층 shrinkage 가 별도 장치가 아니라 켤레 사후분포에서 자동으로 나온다.\n"
            "불확실성의 두 항 분리가 요점: 관측이 늘면 앞 항만 줄고 뒤 항은 남는다. 구간이 무한히 좁아지지 않는다.",
         Inches(0.8), Inches(6.05), Inches(11.7), Inches(0.9), size=13, color=MUTED)
    return s


def s_compare(prs, res):
    s = blank(prs)
    title(s, "14종 모델 비교", "행마다 답하는 질문이 다르게 배치했다 — 모델 수를 늘린 것이 아니다")
    picture(s, "1_wape.png", Inches(0.55), Inches(1.95), h=Inches(5.2))
    x = Inches(7.9)
    text(s, "점 예측 개선 5.3%", x, Inches(2.15), Inches(4.9), Inches(0.6),
         size=24, bold=True, color=ACCENT)
    text(s, "0.1370 → 0.1297", x, Inches(2.8), Inches(4.9), Inches(0.5),
         size=16, color=INK2)
    text(s, "허들 구조는 필요하다\n"
            "  LightGBM 단일 0.1722\n"
            "  → 현행보다 25.7% 나쁘다\n\n"
            "사전학습 모델은 이점 없다\n"
            "  Chronos-2 (120M) 0.1365\n"
            "  → 계절 naive 0.1327 에 미달\n\n"
            "부스팅 구현 차이 무의미\n"
            "  XGBoost 0.1319 vs LGBM 0.1328",
         x, Inches(3.4), Inches(4.9), Inches(3.4), size=14, color=INK)
    return s


def s_change(prs):
    s = blank(prs)
    title(s, "수준을 제거하면 모델이 갈리는가",
          "변화량 WAPE — 1.0 이 “직전 달 복사”와 동등. 최고가 2.3% 개선")
    picture(s, "3_change.png", Inches(1.5), Inches(1.95), h=Inches(5.1))
    text(s, "이 데이터에서 어떤 모델도 직전 달 복사를 유의하게 이기지 못한다. 점 예측을 성능 주장으로 쓸 수 없다.",
         Inches(0.7), Inches(6.95), Inches(11.9), Inches(0.5), size=14,
         bold=True, color=RED, align=PP_ALIGN.CENTER)
    return s


def s_coverage(prs):
    s = blank(prs)
    title(s, "실질 성과 — 구간 신뢰도 캘리브레이션",
          "현행 “80% 구간”은 실제로 65.7%만 덮었다. CQR 적용 후 80.1%")
    picture(s, "2_coverage.png", Inches(0.55), Inches(1.95), h=Inches(5.2))
    x = Inches(7.9)
    text(s, "65.7%  →  80.1%", x, Inches(2.3), Inches(4.9), Inches(0.7),
         size=28, bold=True, color=BLUE)
    text(s, "CQR (Conformalized Quantile Regression)\n\n"
            "보정집합의 적합도 점수\n"
            "  E = max(q₀.₁ − y,  y − q₀.₉)\n"
            "그 분위로 구간을 확장한다.\n\n"
            "분포 가정 없이 유한표본\n"
            "커버리지를 보장한다.\n\n"
            "→ 앱이 표시하는 “신뢰도”가\n"
            "   처음으로 근거를 갖는다",
         x, Inches(3.15), Inches(4.9), Inches(3.6), size=14, color=INK)
    return s


def s_sigma(prs):
    s = blank(prs)
    title(s, "σ 하드코딩 제거", "SPEND_SIGMA = 100,000 → 일정·남은일수 기반 계산 (iOS·백엔드 동일 수식)")
    picture(s, "5_sigma.png", Inches(0.55), Inches(1.95), h=Inches(4.6))
    x = Inches(7.9)
    text(s, "Var[S(Δ)] = Σ Aⱼ²(e^s²−1)\n"
            "          + x̄²( Δe^s² + Δ²CV²λ )",
         x, Inches(2.2), Inches(4.9), Inches(1.0), size=14, color=INK)
    text(s, "둘째 항의 Δ² 이 핵심이다.\n"
            "발생률 자체가 불확실하면 분산이\n"
            "기간에 비례가 아니라 제곱으로 커진다.\n\n"
            "고정 10만원은\n"
            "  월초에 2.4배 과소\n"
            "  월말에 3.8배 과대\n\n"
            "확률 변화 · reduce 88→97\n"
            "         maintain 81→86\n"
            "         increase 74→72",
         x, Inches(3.3), Inches(4.9), Inches(3.4), size=14, color=INK)
    return s


def s_onboard(prs):
    s = blank(prs)
    title(s, "온디바이스 모델이 사용 중에 바뀌는 방식",
          "사용자 1명 26주 시뮬레이션 · 4카테고리 · 20주차에 술 모임 중단")
    rows = [["", "설치 직후", "26주 후", "실제값"],
            ["카페 예상 금액", "8,000원", "4,372원", "4,500원"],
            ["카페 추정 주기", "4.0일", "3.2일", "3일"],
            ["카페 규칙성", "1.00 (가정)", "0.95 (학습)", "1.0"],
            ["외식 추정 주기", "6.0일", "7.0일", "7일"],
            ["카페 80% 구간 폭", "16,776원", "4,755원", "−72%"],
            ["주간 총액 σ", "65,593원", "40,796원", "−38%"]]
    table(s, rows, Inches(0.7), Inches(2.2), Inches(6.6), Inches(2.7),
          col_w=[Inches(2.1), Inches(1.5), Inches(1.5), Inches(1.5)], size=13,
          highlight=(5, 6))
    text(s, "점추정이 맞아가는 것보다\n구간이 좁아지는 폭이 크다",
         Inches(0.7), Inches(5.15), Inches(6.6), Inches(0.9),
         size=17, bold=True, color=ACCENT)
    text(s, "관측이 늘면 모수 불확실성 항만 줄고\n개인 내 변동 항은 남는다 — 구간은 유한한 하한으로 수렴한다.",
         Inches(0.7), Inches(6.05), Inches(6.6), Inches(0.9), size=13, color=MUTED)

    picture(s, "4_detection.png", Inches(7.55), Inches(2.4), h=Inches(3.6))
    text(s, "습관 변화 감지 · 누적만 61주 → 이중 추정기 4주 · 정상 상태 100주 오탐 0회",
         Inches(7.55), Inches(6.15), Inches(5.1), Inches(0.7), size=12, color=MUTED)
    return s


def s_limits(prs):
    s = blank(prs)
    title(s, "미검증 항목", "발표 시 반드시 병기")
    body = (
        "1.  AI Hub 데이터 자체가 합성이다. 실사용자 소비 패턴이 아니다\n"
        "2.  주간 축 · 일정 단건 금액 · 발생 확률은 실데이터로 검증되지 않았다\n"
        "      12개 zip 전부 회원×월 집계이며 거래 단위 레코드가 없다\n"
        "3.  온디바이스 동역학은 시뮬레이션이다. 실사용자 습관 변화로 검증되지 않았다\n"
        "4.  카테고리별 규칙성 k₀ 의 초기값은 도메인 가정이다\n"
        "      공개 데이터에 카테고리별 발생 간격이 존재하지 않는다\n"
        "      측정 가능한 것은 업종 지속률 서열뿐 (납부 83.6% ~ 의료 31.4%)\n"
        "5.  CVλ = 1.0 은 캘리브레이션되지 않은 가정이다\n"
        "6.  Chronos-2 수치는 문맥 4개월 조건이며 성능 상한이 아니다\n"
        "7.  2018년 하반기 데이터로, 현재 물가 수준과 다르다"
    )
    text(s, body, Inches(0.8), Inches(2.2), Inches(11.7), Inches(4.2),
         size=15, color=INK, space_after=8)
    return s


def s_claims(prs):
    s = blank(prs)
    title(s, "쓸 수 있는 문장 / 쓸 수 없는 문장")
    text(s, "쓸 수 있다", Inches(0.8), Inches(2.15), Inches(5.5), Inches(0.5),
         size=19, bold=True, color=BLUE)
    text(s, "· 구간 신뢰도를 65.7% → 80.1% 로 교정했다\n\n"
            "· σ 고정값을 상황 반응 계산으로 대체했다\n\n"
            "· 14종 비교로 무거운 모델이 불필요함을 확인했다\n\n"
            "· 습관 변화 감지를 61주 → 4주로 줄였다 (시뮬레이션)\n\n"
            "· 켤레 사후분포로 서버 전송 없이 개인화된다",
         Inches(0.8), Inches(2.75), Inches(5.6), Inches(3.6), size=14, color=INK)

    text(s, "쓸 수 없다", Inches(6.9), Inches(2.15), Inches(5.5), Inches(0.5),
         size=19, bold=True, color=RED)
    text(s, "· 예측 정확도를 크게 개선했다\n    5.3% 이고, 변화량 기준 2.3% 다\n\n"
            "· 실사용자에서 X% 개선했다\n    실사용자 홀드아웃이 없다\n\n"
            "· 주간 예상 지출 정확도를 검증했다\n    데이터에 주간 축이 없다\n\n"
            "· Chronos 수치가 성능 상한이다\n    문맥 4개월 조건이다",
         Inches(6.9), Inches(2.75), Inches(5.6), Inches(3.6), size=14, color=INK)
    return s


def main() -> None:
    res = pd.read_csv(RES / "results.csv")
    prs = Presentation()
    prs.slide_width, prs.slide_height = W, H

    s_cover(prs)
    s_problem(prs)
    s_data(prs)
    s_autocorr(prs)
    s_model(prs)
    s_math(prs)
    s_compare(prs, res)
    s_change(prs)
    s_coverage(prs)
    s_sigma(prs)
    s_onboard(prs)
    s_limits(prs)
    s_claims(prs)

    out = RES / "KB_Tune_예측모델.pptx"
    prs.save(out)
    print(f"{out}  ({len(prs.slides.__iter__.__self__._sldIdLst)} 슬라이드)")


if __name__ == "__main__":
    main()
