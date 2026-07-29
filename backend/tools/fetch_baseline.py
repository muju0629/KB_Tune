"""공개 데이터 → baseline_prices.json 재생성.

앱이 쓰는 기준 금액은 손으로 적은 숫자가 아니라 이 스크립트가 만든 값이다.
숫자를 의심할 일이 생기면 이걸 다시 돌려서 원본과 대조한다.

    python -m tools.fetch_baseline            # backend/data/baseline_prices.json 갱신

출처 네 곳:
  1. 한국소비자원 참가격 — 외식비 1인분 단가, 개인서비스요금 (전국 16개 시도, 월 단위)
  2. 국가데이터처 가계동향조사 — 1인가구 12대 비목 월평균 소비지출 (분기)
  3. 서울열린데이터광장 상권분석 — 업종·연령대별 카드 결제 건당 금액 (서울, 분기)
  4. 영화진흥위원회 결산 — 평균 관람요금 (연 1회, 수기 상수)

1·2는 전국이라 기준 금액(base)으로 쓰고, 3은 서울 한정이라 연령 보정 계수로만 쓴다.
"""
from __future__ import annotations

import io
import json
import os
import re
import ssl
import sys
import urllib.parse
import urllib.request
import urllib.robotparser
from collections import defaultdict
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "data" / "baseline_prices.json"

PRICE_DINEOUT = "https://www.price.go.kr/tprice/portal/servicepriceinfo/dineoutprice/dineOutPriceList.do"
PRICE_SERVICE = "https://www.price.go.kr/tprice/portal/servicepriceinfo/serviceindustryprice/serviceIndustryPriceList.do"
KOSTAT_XLSX = "https://mods.go.kr/boardDownload.es?bid=214&list_no=445277&seq=3"
SEOUL_API = "http://openapi.seoul.go.kr:8088/{key}/json/VwsmSignguSelngW/{start}/{end}/"

# 참가격은 인증서 체인이 끊겨 있어 표준 검증을 통과하지 못한다. 공개 통계 페이지이고
# 받아오는 값이 화면과 같은지 아래 파서가 형식까지 확인하므로 이 두 URL에서만 완화한다.
_LAX = ssl.create_default_context()
_LAX.check_hostname = False
_LAX.verify_mode = ssl.CERT_NONE

UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) KB-Tune-baseline/1.0"}


def _fetch(url: str, lax: bool = False) -> bytes:
    req = urllib.request.Request(url, headers=UA)
    ctx = _LAX if lax else None
    with urllib.request.urlopen(req, timeout=60, context=ctx) as r:
        return r.read()


# 호스트별 robots.txt 파서. None 은 '읽지 못해 판단 보류'다.
_ROBOTS: dict[str, urllib.robotparser.RobotFileParser | None] = {}


def _robots_allows(url: str, lax: bool = False) -> bool:
    """로봇배제표준(robots.txt) 확인.

    개인정보보호위원회 「AI 개발·서비스를 위한 공개된 개인정보 처리 안내서」(2024.7)
    Ⅲ-1-1 이 스크래핑 시 로봇배제표준 준수를 요구한다. 여기서 받아오는 것은 개인이
    없는 공표 통계라 그 안내서의 적용 대상은 아니지만, 지키는 편이 '공표 통계만
    가져온다'는 말을 단단하게 한다.

    robots.txt 가 없으면(404) 제한이 없다는 뜻이므로 허용으로 본다. 참가격은 인증서
    체인이 끊겨 있어 robots.txt 도 같은 완화 설정으로 읽는다.
    """
    parts = urllib.parse.urlsplit(url)
    host = f"{parts.scheme}://{parts.netloc}"
    if host not in _ROBOTS:
        parser = urllib.robotparser.RobotFileParser()
        try:
            body = _fetch(host + "/robots.txt", lax=lax).decode("utf-8", "replace")
            parser.parse(body.splitlines())
        except Exception:
            parser = None
        _ROBOTS[host] = parser
    parser = _ROBOTS[host]
    return parser is None or parser.can_fetch(UA["User-Agent"], url)


def _get(url: str, lax: bool = False) -> bytes:
    if not _robots_allows(url, lax=lax):
        raise RuntimeError(f"robots.txt 가 이 경로를 막고 있다: {url}")
    return _fetch(url, lax=lax)


# ---------- 1. 한국소비자원 참가격 ----------

def _price_table(url: str, columns: list[str]) -> tuple[dict[str, dict], str]:
    """참가격 지역별 표 → (품목별 {전국평균·최저·최고}, 기준 연월).

    표는 16개 시도 × 품목 행렬이고 값은 3,838 꼴의 쉼표 숫자다. 지역 이름을
    앵커로 잡아 그 뒤 숫자를 열 순서대로 읽는다. 범위는 시도 간 실측 최저~최고다.
    """
    html = _get(url, lax=True).decode("utf-8", "replace")

    year = re.search(r'<option value="(\d{4})" selected', html)
    month = re.search(r'<option value="(\d{2})" selected', html)
    if not (year and month):
        raise RuntimeError(f"기준 연월을 못 찾음: {url}")
    asof = f"{year.group(1)}-{month.group(1)}"

    body = re.sub(r"<(script|style)[^>]*>.*?</\1>", "", html, flags=re.S)
    # 표 한 칸 사이에 태그와 공백이 수십 자씩 끼어 있다. 전부 구분자 하나로 접고
    # 지역 이름 뒤에 이어지는 숫자를 열 순서대로 읽는다.
    text = re.sub(r"[\s|]+", "|", re.sub(r"<[^>]+>", "|", body))

    regions = ["서울", "광주", "대구", "대전", "부산", "울산", "인천", "강원", "경기",
               "경남", "경북", "전남", "전북", "충남", "충북", "제주"]
    totals: dict[str, list[int]] = defaultdict(list)
    for region in regions:
        m = re.search(r"\|" + region + r"\|", text)
        if not m:
            raise RuntimeError(f"{region} 행을 못 찾음: {url}")
        nums = re.findall(r"\d{1,3}(?:,\d{3})+", text[m.end():], )[:len(columns)]
        if len(nums) < len(columns):
            raise RuntimeError(f"{region} 행의 값이 {len(nums)}개뿐: {url}")
        for name, raw in zip(columns, nums):
            totals[name].append(int(raw.replace(",", "")))

    return ({k: {"amount": round(sum(v) / len(v)), "low": min(v), "high": max(v)}
             for k, v in totals.items()}, asof)


# 표의 열 순서. 삼겹살은 환산전·환산후 두 열이라 200g 기준인 환산후만 남긴다.
DINEOUT_COLUMNS = ["냉면", "비빔밥", "김치찌개백반", "_삼겹살환산전", "삼겹살200g",
                   "자장면", "삼계탕", "칼국수", "김밥"]
SERVICE_COLUMNS = ["세탁", "숙박여관", "이용", "미용", "목욕"]


def fetch_chamgagyeok() -> dict:
    dineout, dineout_asof = _price_table(PRICE_DINEOUT, DINEOUT_COLUMNS)
    dineout.pop("_삼겹살환산전", None)
    service, service_asof = _price_table(PRICE_SERVICE, SERVICE_COLUMNS)
    return {"dineout": dineout, "dineout_asof": dineout_asof,
            "service": service, "service_asof": service_asof}


# ---------- 2. 가계동향조사 ----------

BIMOK = ["식료품·비주류음료", "주류·담배", "의류·신발", "주거·수도·광열",
         "가정용품·가사서비스", "보건", "교통·운송", "정보통신", "오락·문화",
         "교육", "음식·숙박", "기타상품·서비스"]


def fetch_household() -> dict:
    """1인가구 12대 비목 월평균 소비지출(원). 통계표 1.8 가구원수별 가계수지."""
    import openpyxl

    wb = openpyxl.load_workbook(io.BytesIO(_get(KOSTAT_XLSX)), data_only=True)
    sheet = next(s for s in wb.sheetnames if s.startswith("1.8"))
    ws = wb[sheet]

    rows = {}
    quarter = None
    for row in ws.iter_rows(values_only=True):
        cells = [("" if v is None else str(v).replace("\n", " ").strip()) for v in row]
        if not cells:
            continue
        if quarter is None:
            q = next((c for c in cells if re.fullmatch(r"\d{4}\.\s*\d/4", c)), None)
            if q:
                quarter = q.replace(" ", "")
        label = re.sub(r"\s+", "", cells[0])
        # 1인가구 금액은 '구분 | (A/B) | 금액 | 증감' 순서라 세 번째 숫자 칸이다.
        nums = [c for c in cells[1:] if re.fullmatch(r"-?\d+(\.\d+)?", c)]
        if label and nums:
            rows[label] = nums

    def pick(label: str) -> int:
        key = re.sub(r"\s+", "", label)
        if key not in rows:
            raise RuntimeError(f"가계동향조사에서 '{label}' 행을 못 찾음")
        return int(float(rows[key][0]) * 1000)   # 천원 → 원

    monthly = {b: pick(b) for b in BIMOK}
    monthly["소비지출"] = pick("소비지출")
    if not quarter:
        raise RuntimeError("가계동향조사 기준 분기를 못 찾음")
    return {"one_person_monthly": monthly, "asof": quarter}


# ---------- 3. 서울 상권분석 (연령대별) ----------

AGES = ["10", "20", "30", "40", "50", "60_ABOVE"]


def fetch_seoul(key: str) -> dict:
    """업종 × 연령대별 카드 결제 건당 금액(원), 최신 분기 · 25개 자치구 합산."""
    def call(start: int, end: int) -> dict:
        raw = _get(SEOUL_API.format(key=key, start=start, end=end))
        return json.loads(raw)["VwsmSignguSelngW"]

    total = call(1, 1)["list_total_count"]
    rows = []
    for start in range(1, total + 1, 1000):
        rows += call(start, min(start + 999, total))["row"]

    latest = max(r["STDR_YYQU_CD"] for r in rows)
    rows = [r for r in rows if r["STDR_YYQU_CD"] == latest]

    # amount[업종][연령] = [매출금액 합, 매출건수 합]
    amount: dict[str, dict[str, list[float]]] = defaultdict(
        lambda: defaultdict(lambda: [0.0, 0.0]))
    by_district: dict[str, list[int]] = defaultdict(list)
    for r in rows:
        biz = r["SVC_INDUTY_CD_NM"]
        amount[biz]["전체"][0] += r["THSMON_SELNG_AMT"] or 0
        amount[biz]["전체"][1] += r["THSMON_SELNG_CO"] or 0
        for age in AGES:
            amount[biz][age][0] += r[f"AGRDE_{age}_SELNG_AMT"] or 0
            amount[biz][age][1] += r[f"AGRDE_{age}_SELNG_CO"] or 0
        if (r["THSMON_SELNG_CO"] or 0) >= 1_000:
            by_district[biz].append(round(r["THSMON_SELNG_AMT"] / r["THSMON_SELNG_CO"]))

    # 건수가 적은 업종·연령은 건당 금액이 크게 튄다. 분기 1,000건 미만은 버린다.
    per_unit: dict[str, dict[str, int]] = {}
    for biz, by_age in amount.items():
        vals = {a: round(s / c) for a, (s, c) in by_age.items() if c >= 1_000}
        spread = sorted(by_district.get(biz, []))
        if "전체" in vals and len(spread) >= 5:
            # 자치구 최저·최고를 그대로 쓰면 도매·법인 결제 한 곳에 범위가 끌려간다.
            # 10~90 백분위로 잘라 실제로 흔한 구간만 남긴다.
            vals["_low"] = spread[int(len(spread) * 0.1)]
            vals["_high"] = spread[min(len(spread) - 1, int(len(spread) * 0.9))]
            per_unit[biz] = vals

    return {"per_transaction": per_unit,
            "asof": f"{latest[:4]}-{latest[4]}/4",
            "districts": len({r["SIGNGU_CD_NM"] for r in rows})}


# ---------- 4. 영화진흥위원회 ----------

# 2025년 결산 극장 매출 1조 470억 원 ÷ 관객 1억 609만 명. KOFIC 이 평균 관람요금을
# 별도 항목으로 공표하지 않아 두 공표값에서 계산했다(연 1회 갱신).
KOFIC = {"평균관람요금": round(1_047_000_000_000 / 106_090_000), "asof": "2025"}


# ---------- 조립 ----------

# (표시 이름, 제목에서 찾을 검색어, 상권분석 업종명)
#
# **결제 1건이 방문 1회인 업종만** 넣는다. 학원 수강료(일반교습학원 32만원)나
# 헬스 회원권(스포츠클럽 19만원)은 한 번 긁고 몇 달을 쓰는 돈이라, '학원 가기'라는
# 일정에 그 금액을 붙이면 크게 틀린다. 장보기(슈퍼마켓·청과상)와 가전·가구처럼
# 애초에 일정으로 잡지 않는 업종도 뺀다.
CARD_ITEMS: list[tuple[str, list[str], str]] = [
    # 먹는 것
    ("편의점", ["편의점"], "편의점"),
    ("제과점", ["빵", "베이커리", "제과"], "제과점"),
    ("분식", ["분식", "떡볶이"], "분식전문점"),
    ("패스트푸드", ["햄버거", "버거", "패스트푸드"], "패스트푸드점"),
    ("치킨", ["치킨"], "치킨전문점"),
    ("중식", ["중식", "중국집"], "중식음식점"),
    ("일식", ["일식", "초밥", "스시", "회식당"], "일식음식점"),
    # 몸
    ("치과", ["치과"], "치과의원"),
    ("약국", ["약국", "약 사기"], "의약품"),
    ("병원", ["병원", "의원", "내과", "이비인후과", "정형외과", "진료"], "일반의원"),
    ("한의원", ["한의원", "한방"], "한의원"),
    ("안경", ["안경", "렌즈"], "안경"),
    ("네일", ["네일"], "네일숍"),
    ("피부관리", ["피부관리", "에스테틱"], "피부관리실"),
    # 사는 것
    ("화장품", ["화장품", "올리브영"], "화장품"),
    ("신발", ["신발", "운동화"], "신발"),
    ("가방", ["가방"], "가방"),
    ("문구", ["문구", "필기구"], "문구"),
    ("서적", ["서점", "교재", "책 사기"], "서적"),
    # 노는 것
    ("PC방", ["PC방", "피시방"], "PC방"),
    ("노래방", ["노래방", "코노"], "노래방"),
    ("당구", ["당구", "포켓볼"], "당구장"),
    ("골프연습장", ["골프", "스크린"], "골프연습장"),
    # 그 밖
    ("세차", ["세차"], "자동차미용"),
    ("반려동물", ["반려동물", "애견", "강아지", "고양이", "동물병원"], "애완동물"),
]

def build(cham: dict, house: dict, seoul: dict) -> dict:
    dineout = cham["dineout"]
    service = cham["service"]
    card = seoul["per_transaction"]

    cham_src = f"한국소비자원 참가격 ({cham['dineout_asof']}, 전국 16개 시도)"
    svc_src = f"한국소비자원 참가격 개인서비스요금 ({cham['service_asof']}, 전국 16개 시도)"
    card_src = (f"서울열린데이터광장 상권분석 카드매출 "
                f"({seoul['asof']}, 서울 {seoul['districts']}개 자치구)")

    def from_card(category: str, biz: str, basis: str) -> dict:
        """업종 하나의 카드 결제 건당 금액 → 일정 한 건 기준값.

        범위는 자치구 간 실측 최저~최고, 연령 보정은 전체 대비 배수다. 서울 값이라
        전국 기준값 대신 쓰지만, 배수는 지역색이 약해 다른 출처의 기준값에도 붙인다.
        """
        v = card[biz]
        return {
            "category": category, "amount": v["전체"],
            "low": v["_low"], "high": v["_high"],
            "age_factors": {a: round(v[a] / v["전체"], 3)
                            for a in ("20", "30", "40", "50") if a in v},
            "basis": basis, "source": card_src,
        }

    # 1인분 단가의 대표값. 삼겹살은 200g(≈2인분) 기준이라 뺀다.
    solo = {k: v for k, v in dineout.items() if k != "삼겹살200g"}
    solo_avg = round(sum(v["amount"] for v in solo.values()) / len(solo))
    한식 = card["한식음식점"]

    # basis 에는 금액을 적지 않는다. 연령 배수를 곱하고 나면 문장 속 숫자와 실제로
    # 보여주는 금액이 어긋난다(여행 20,000원인데 '46,234원을 기준으로'라고 말하는 식).
    # 금액은 화면에 따로 나오니 여기서는 '무엇을 잰 값인지'만 말한다.

    events = [
        # 외식은 '내가 먹은 1인분'이라 참가격 단가를 쓴다. 카드 건당 금액은 동석자
        # 몫까지 한 건에 묶여 1인 기준으로는 과대추정이다.
        {"category": "외식", "amount": solo_avg,
         "low": min(v["amount"] for v in solo.values()),
         "high": max(v["amount"] for v in solo.values()),
         "age_factors": {a: round(한식[a] / 한식["전체"], 3)
                         for a in ("20", "30", "40", "50") if a in 한식},
         "basis": f"전국 외식 1인분 {len(solo)}품목 평균", "source": cham_src},

        from_card("카페", "커피-음료", "커피·음료 카드 결제 1건 평균"),
        from_card("모임", "호프-간이주점", "호프·간이주점 카드 결제 1건 평균"),
        from_card("데이트", "양식음식점", "양식음식점 카드 결제 1건 평균"),
        from_card("가족", "한식음식점", "한식음식점 카드 결제 1건 평균"),
        from_card("자기관리", "미용실", "미용실 카드 결제 1건 평균"),
        from_card("쇼핑", "일반의류", "일반의류 카드 결제 1건 평균"),

        # 여행은 숙박 1박만 잡는다. 교통·식비·입장료는 며칠인지 몇 명인지에 따라
        # 몇 배씩 달라져서, 공개 통계로 '여행 한 건'을 통째로 맞히는 건 불가능하다.
        # 아래 금액을 '최소한 이만큼'으로 보여주고 나머지는 사용자에게 묻는 게 정직하다.
        #
        # 연령 배수를 일부러 안 붙였다. 참가격 숙박은 1박 요금인데 상권분석 여관 결제는
        # 대실이 섞여 있어(20대 22,171원) 둘이 같은 행위를 재지 않는다. 서로 다른 걸
        # 잰 값끼리 곱하면 1박에 20,000원 같은 숫자가 나온다.
        {"category": "여행", "amount": service["숙박여관"]["amount"],
         "low": service["숙박여관"]["low"], "high": service["숙박여관"]["high"],
         "basis": "숙박 1박 전국 평균(교통·식비 별도)",
         "source": svc_src},

        # 업무·학업(스터디·팀플·회의)과 경조사(축의금)는 기준값을 넣지 않는다. 공개 통계에
        # 대응하는 업종이 없고, 서적·예식장 결제액은 그 일정에 쓰는 돈과 다른 행동이다.
        # 이 둘은 기존 규칙과 개인 이력으로만 추정한다.

        # 문화·여가는 앱 규칙에서 둘 다 영화·공연·전시를 잡는다. 1인 관람료 기준.
        {"category": "문화", "amount": KOFIC["평균관람요금"],
         "low": round(KOFIC["평균관람요금"] * 0.7), "high": round(KOFIC["평균관람요금"] * 2),
         "basis": "영화 평균 관람요금",
         "source": f"영화진흥위원회 결산 ({KOFIC['asof']})"},
        {"category": "여가", "amount": KOFIC["평균관람요금"],
         "low": round(KOFIC["평균관람요금"] * 0.7), "high": round(KOFIC["평균관람요금"] * 2),
         "basis": "영화 평균 관람요금",
         "source": f"영화진흥위원회 결산 ({KOFIC['asof']})"},
    ]

    def item(name: str, keywords: list[str], table: dict, source: str, key: str) -> dict:
        v = table[key]
        return {"name": name, "keywords": keywords, "amount": v["amount"],
                "low": v["low"], "high": v["high"], "source": source}

    items = [item(n, [n], dineout, cham_src, n)
             for n in sorted(dineout, key=lambda k: dineout[k]["amount"])
             if n != "삼겹살200g"]
    # 표기가 '삼겹살200g'·'숙박여관'이라 제목에 그대로 나올 리 없다. 검색어를 따로 준다.
    items.append(item("삼겹살", ["삼겹살", "고깃집", "고기집"], dineout, cham_src, "삼겹살200g"))
    items += [item(n, k, service, svc_src, n) for n, k in (
        ("미용", ["미용실", "머리", "커트", "펌", "염색"]),
        ("이용", ["이발", "이용원"]),
        ("목욕", ["목욕", "사우나", "찜질방"]),
        ("세탁", ["세탁", "드라이"]),
        ("숙박여관", ["숙박", "여관", "모텔", "1박"]),
    )]
    items += [{"name": name, "keywords": keywords, "amount": card[biz]["전체"],
               "low": card[biz]["_low"], "high": card[biz]["_high"], "source": card_src}
              for name, keywords, biz in CARD_ITEMS]

    return {
        "version": f"{house['asof']}+{cham['dineout_asof']}+{seoul['asof']}",
        "events": events,
        "items": items,
        "monthly": {
            "scope": "1인가구 전국",
            "asof": house["asof"],
            "source": f"국가데이터처 가계동향조사 ({house['asof']})",
            "total": house["one_person_monthly"]["소비지출"],
            "bimok": [{"bimok": b, "amount": house["one_person_monthly"][b]} for b in BIMOK],
        },
    }


def main() -> int:
    key = os.environ.get("SEOUL_OPENAPI_KEY", "").strip()
    if not key:
        print("SEOUL_OPENAPI_KEY 가 없다. backend/.env 에 넣고 다시 실행한다.", file=sys.stderr)
        return 1

    print("참가격…", flush=True)
    cham = fetch_chamgagyeok()
    print("가계동향조사…", flush=True)
    house = fetch_household()
    print("서울 상권분석…", flush=True)
    seoul = fetch_seoul(key)

    data = build(cham, house, seoul)
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{OUT} — 일정 {len(data['events'])}종 · 품목 {len(data['items'])}종 "
          f"· 비목 {len(data['monthly']['bimok'])}종 (version {data['version']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
