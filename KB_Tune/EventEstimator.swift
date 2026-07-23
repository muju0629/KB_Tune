//
//  EventEstimator.swift
//  KB_Tune
//
//  일정 제목 → 예상 지출 범위 추정.
//  1순위는 백엔드 /api/estimate, 실패하면 같은 7월 일정 기준으로 로컬에서 계산한다.
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

    /// (카테고리, 키워드, 기본금액)
    private static let rules: [(String, [String], Int)] = [
        ("출근", ["인포스탁", "인턴", "출근"], 0),          // 점심·교통 비용 없음(고정비에 포함)
        ("경조사", ["결혼", "축의", "장례", "부의", "청첩"], 70_000),
        ("데이트", ["데이트", "200일", "기념일"], 65_000),
        ("가족", ["가족식사", "가족모임"], 20_000),
        ("자기관리", ["레이저", "제모", "병원", "한의원", "의원"], 25_000),
        ("여가", ["영화", "공연", "전시", "미술관", "콘서트"], 20_000),
        ("모임", ["회식", "술", "뒤풀이", "동아리", "모임", "저녁"], 25_000),
        ("카페", ["카페", "커피", "스터디", "팀플", "연구"], 8_000),
        ("외식", ["점심", "식사", "밥", "맛집", "런치", "디너"], 15_000),
        ("쇼핑", ["정장", "쇼핑", "구매", "교재", "옷", "선물"], 40_000),
        ("교통", ["이동", "택시", "기차", "버스"], 10_000),
    ]

    /// 제공된 7월 캘린더의 같은 유형 일정으로 잡은 건당 기준값.
    private static let calendarEstimate: [String: (avg: Int, low: Int, high: Int)] = [
        "출근": (0, 0, 0),
        "경조사": (70_000, 70_000, 70_000),
        "데이트": (65_000, 30_000, 100_000),
        "가족": (20_000, 20_000, 20_000),
        "자기관리": (35_000, 20_000, 50_000),
        "여가": (20_000, 8_000, 50_000),
        "모임": (25_000, 5_000, 50_000),
        "카페": (8_000, 5_000, 10_000),
        "외식": (20_000, 15_000, 30_000),
        "교통": (10_000, 5_000, 15_000),
    ]

    static func estimate(_ title: String) -> EstimateResponse {
        let t = title.replacingOccurrences(of: " ", with: "")

        // 1순위: 과거에 같은 일정을 쓴 적이 있으면 그 이력이 규칙보다 정확하다.
        if let p = SpendHistory.predict(title: title) {
            return EstimateResponse(
                title: title, category: SpendHistory.category(for: title) ?? "기타",
                amount: p.amount, low: p.low, high: p.high, confidence: p.confidence,
                basis: "\(p.reason) \(p.detail)",
                method: "history"
            )
        }

        if t.contains("회의") {
            return EstimateResponse(
                title: title, category: "업무·학업", amount: 0,
                low: 0, high: 0, confidence: 1,
                basis: "성제님의 회의는 별도 비용 없음으로 설정했어요.",
                method: "local"
            )
        }

        if t.contains("와드") {
            return EstimateResponse(
                title: title, category: "업무·학업", amount: 40_000,
                low: 40_000, high: 40_000, confidence: 1,
                basis: "성제님이 확인한 금액을 반영했어요.",
                method: "local"
            )
        }

        if t.contains("레이저") || t.contains("제모") {
            return EstimateResponse(
                title: title, category: "자기관리", amount: 50_000,
                low: 50_000, high: 50_000, confidence: 1,
                basis: "당일 결제 50,000원으로 확인된 금액이에요.",
                method: "local"
            )
        }

        if t.contains("200일") || t.contains("기념일") {
            return EstimateResponse(
                title: title, category: "데이트", amount: 100_000,
                low: 70_000, high: 150_000, confidence: 0.4,
                basis: "장소와 선물이 정해지지 않아 기념일 예산 범위로 잡았어요.",
                method: "local"
            )
        }

        if t.contains("결혼") || t.contains("축의") || t.contains("청첩") {
            return EstimateResponse(
                title: title, category: "경조사", amount: 70_000,
                low: 50_000, high: 100_000, confidence: 0.6,
                basis: "지난 결혼식 때 축의금·교통비로 7만원 정도 쓰셨어요.",
                method: "history"
            )
        }

        if t.contains("정장") {
            return EstimateResponse(
                title: title, category: "쇼핑", amount: 150_000,
                low: 150_000, high: 150_000, confidence: 1,
                basis: "확인된 구매 금액 150,000원이에요.",
                method: "local"
            )
        }

        var category = "기타"
        var base = 20_000

        for (cat, keys, def) in rules where keys.contains(where: { t.contains($0) }) {
            category = cat
            base = def
            break
        }

        if let estimate = calendarEstimate[category] {
            return EstimateResponse(
                title: title, category: category, amount: estimate.avg,
                low: estimate.low, high: estimate.high, confidence: 0.7,
                basis: "7월에 잡힌 비슷한 일정의 금액을 썼어요.",
                method: "local"
            )
        }

        return EstimateResponse(
            title: title, category: category, amount: base,
            low: Int(Double(base) * 0.6), high: Int(Double(base) * 1.6),
            confidence: 0.3,
            basis: "일정 제목만으로 금액을 확정하기 어려워 넓게 잡았어요.",
            method: "local"
        )
    }
}
