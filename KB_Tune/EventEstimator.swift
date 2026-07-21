//
//  EventEstimator.swift
//  KB_Tune
//
//  AI 기능 ① 앱 절반 — 일정 제목 → 예상 지출 추정.
//  1순위: 백엔드 /api/estimate (과거 거래 이력으로 개인화)
//  폴백  : 아래 로컬 추정기 (백엔드 없어도 동작 · 백엔드와 동일 규칙/기준값)
//

import Foundation

/// 백엔드 EstimateResult 와 동일 스키마
struct EstimateResponse: Codable {
    let title: String
    let category: String
    let amount: Int
    let low: Int
    let high: Int
    let confidence: Double
    let basis: String
    let method: String      // rule | history | llm | local
}

enum EventEstimator {

    /// (카테고리, 키워드, 기본금액) — 백엔드 EVENT_RULES 와 동일
    private static let rules: [(String, [String], Int)] = [
        ("경조사", ["결혼", "축의", "돌잔치", "장례", "부의", "청첩"], 150_000),
        ("여행", ["여행", "MT", "엠티", "워크샵", "워크숍", "숙박", "펜션"], 200_000),
        ("술·모임", ["회식", "술", "2차", "뒤풀이", "동아리", "모임", "파티", "생일"], 30_000),
        ("여가", ["영화", "공연", "전시", "콘서트", "페스티벌", "노래방", "볼링"], 15_000),
        ("카페", ["카페", "커피", "스터디", "팀플", "과제"], 8_000),
        ("외식", ["점심", "저녁", "식사", "밥", "맛집", "고기", "런치", "디너"], 15_000),
        ("쇼핑", ["쇼핑", "구매", "교재", "옷", "선물"], 40_000),
    ]

    /// 데모 페르소나의 과거 3개월 '건당 평균' (백엔드 히스토리에서 산출된 값과 동일)
    private static let historyAvg: [String: (avg: Int, low: Int, high: Int)] = [
        "술·모임": (30_000, 25_000, 35_000),
        "카페": (8_000, 8_000, 8_000),
        "외식": (17_500, 17_500, 17_500),
        "쇼핑": (40_000, 40_000, 40_000),
        "교통": (30_000, 30_000, 30_000),
        "배달": (10_000, 10_000, 10_000),
        "구독": (15_000, 15_000, 15_000),
    ]

    static func estimate(_ title: String) -> EstimateResponse {
        let t = title.replacingOccurrences(of: " ", with: "")
        var category = "기타"
        var base = 20_000

        for (cat, keys, def) in rules where keys.contains(where: { t.contains($0) }) {
            category = cat
            base = def
            break
        }

        if let h = historyAvg[category] {
            return EstimateResponse(
                title: title, category: category, amount: h.avg,
                low: h.low, high: h.high, confidence: 0.85,
                basis: "지난 3개월 ‘\(category)’ 지출 평균 \(h.avg.formatted(.number.grouping(.automatic)))원 기준이에요.",
                method: "local"
            )
        }

        return EstimateResponse(
            title: title, category: category, amount: base,
            low: Int(Double(base) * 0.6), high: Int(Double(base) * 1.6),
            confidence: category == "기타" ? 0.4 : 0.5,
            basis: "과거 이력이 적어 일반적인 ‘\(category)’ 지출로 잡았어요.",
            method: "local"
        )
    }
}
