//
//  EventEstimator.swift
//  KB_Tune
//
//  일정 제목 → 예상 지출 범위 추정.
//  기기 안에서만 계산한다 — 제목은 어떤 경로로도 서버에 나가지 않는다.
//
//  값을 고르는 순서는 '이 사람에게 얼마나 가까운가'다.
//    1. 이 사람이 같은 일정에 실제로 쓴 금액
//    2. 이 사람의 같은 카테고리 결제 이력(2건 이상)
//    3. 공개 통계 기준 금액(BaselinePrices) — 이력이 없는 사람도 여기서 값을 받는다
//    4. 규칙에 박아 둔 최후 기본값
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
    let method: String      // rule | history | baseline | llm | local
}

enum EventEstimator {

    /// (카테고리, 키워드, 기본금액)
    private static let rules: [(String, [String], Int)] = [
        ("출근", ["인포스탁", "인턴", "출근"], 0),          // 점심·교통 비용 없음(고정비에 포함)
        ("경조사", ["결혼", "축의", "장례", "부의", "청첩"], 70_000),
        // 경조사 뒤에 둔다 — "호텔 결혼식"처럼 숙박 낱말이 섞인 경조사를 여행으로 뺏기지 않게.
        ("여행", ["여행", "휴가", "숙박", "펜션", "리조트", "캠핑"], 150_000),
        ("데이트", ["데이트", "200일", "기념일"], 65_000),
        ("가족", ["가족식사", "가족모임"], 20_000),
        ("자기관리", ["레이저", "제모", "병원", "한의원", "의원", "치과", "네일",
                      "피부관리", "약국", "안경", "진료", "미용실"], 25_000),
        ("여가", ["영화", "공연", "전시", "미술관", "콘서트"], 20_000),
        ("모임", ["회식", "술", "뒤풀이", "동아리", "모임", "저녁"], 25_000),
        ("카페", ["카페", "커피", "스터디", "팀플", "연구"], 8_000),
        ("외식", ["점심", "식사", "밥", "맛집", "런치", "디너"], 15_000),
        // "구입"이 없어서 `맥미니 구입하기` 가 기타로 떨어졌다. 한 글자 차이로 근거 없는
        // 기본값까지 미끄러진다. 짧은 낱말은 오매칭이 나므로("지름길"→지름) 늘리지 않는다.
        ("쇼핑", ["정장", "쇼핑", "구매", "구입", "장만", "교재", "옷", "선물"], 40_000),
        ("교통", ["이동", "택시", "기차", "버스"], 10_000),
    ]

    /// 공개 통계에 대응하는 업종이 없어 BaselinePrices 가 답을 못 주는 카테고리들.
    /// 여기 값은 성제의 7월 캘린더에서 온 것이라 남에게 그대로 쓰면 근거가 없다 —
    /// 그래서 표에 있는 카테고리는 항상 표를 먼저 본다.
    private static let calendarEstimate: [String: (avg: Int, low: Int, high: Int)] = [
        "출근": (0, 0, 0),
        "경조사": (70_000, 70_000, 70_000),
        "교통": (10_000, 5_000, 15_000),
    ]

    /// 온보딩에서 받은 나이대("20"·"30"·"40"·"50"). 선택 입력이라 비어 있는 게 정상이다.
    /// 기기 밖으로 내보내지 않고 기준 금액에 배수를 곱하는 데에만 쓴다.
    static var ageBucket: String? {
        let v = UserDefaults.standard.string(forKey: "kbTuneAgeBucket") ?? ""
        return v.isEmpty ? nil : v      // 온보딩에서 안 고르면 빈 문자열로 남는다
    }

    static func estimate(_ title: String, history: [SpendRecord]? = nil) -> EstimateResponse {
        let t = title.replacingOccurrences(of: " ", with: "")
        let source = history ?? SpendHistory.allRecords

        // 1순위: 과거에 같은 일정을 쓴 적이 있으면 그 이력이 규칙보다 정확하다.
        if let p = SpendHistory.predict(title: title, in: source) {
            return EstimateResponse(
                title: title, category: SpendHistory.category(for: title, in: source) ?? "기타",
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

        // 그 카테고리 결제가 한 건이라도 있으면 예측 모델에 맡긴다 — 모델은 기록을 피처로
        // 받으므로 기록이 있을 때만 그 사람의 값이 된다. 기록이 없으면 인구 평균으로
        // 수렴하니 아래 공개 통계(BaselinePrices)가 더 정직하다.
        if source.contains(where: { $0.category == category }),
           let m = ForecastEngine.eventAmount(category: category, records: source,
                                              on: DemoClock.today) {
            return EstimateResponse(
                title: title, category: category, amount: m.amount,
                low: m.low, high: m.high, confidence: 0.75,
                basis: "예측 모델이 기기 안 \(category) 결제 기록으로 추정한 금액이에요. 보통 \(formatWon(m.low))~\(formatWon(m.high)) 사이로 봤어요.",
                method: "forecast"
            )
        }

        // 모델이 모르는 카테고리는 개인 결제 이력으로 — 표본이 한 건뿐이면 우연일 수 있어
        // 최소 2건부터 중앙값을 대표값으로 삼는다.
        if let personal = SpendHistory.representative(for: category, in: source) {
            let confidence = min(0.92, 0.55 + Double(personal.sampleCount) * 0.07)
            return EstimateResponse(
                title: title, category: category, amount: personal.amount,
                low: personal.low, high: personal.high, confidence: confidence,
                basis: "기기에 저장된 \(category) 결제 \(personal.sampleCount)건으로 추정한 금액이에요. 지금까지 \(formatWon(personal.low))~\(formatWon(personal.high)) 사이로 쓰셨어요.",
                method: "history"
            )
        }

        // 개인 이력이 없는 사람. 임의의 숫자 대신 공개 통계에서 가져오고 출처를 같이 보여준다.
        if let base = BaselinePrices.forTitle(title)
            ?? BaselinePrices.forCategory(category, ageBucket: ageBucket) {
            return EstimateResponse(
                title: title, category: category, amount: base.amount,
                low: base.low, high: base.high, confidence: 0.55,
                basis: "\(base.basis)을 기준으로 잡았어요. 출처는 \(base.source).",
                method: "baseline"
            )
        }

        if let estimate = calendarEstimate[category] {
            return EstimateResponse(
                title: title, category: category, amount: estimate.avg,
                low: estimate.low, high: estimate.high, confidence: 0.7,
                basis: "비슷한 일정에 보통 드는 금액으로 잡았어요.",
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
