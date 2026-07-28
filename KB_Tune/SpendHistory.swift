//
//  SpendHistory.swift
//  KB_Tune
//
//  과거 소비 이력(5~6월)과 반복 패턴 탐지 엔진.
//
//  캘린더에 일정만 있고 금액이 없을 때, 같은 일정을 과거에 얼마나 자주·얼마씩 썼는지
//  찾아 금액을 예측하고 "왜 그렇게 봤는지"를 사람 말로 만든다.
//  탐지·계산은 전부 결정론이다 — LLM은 문장만 다듬는다.
//

import Foundation

/// 과거 지출 한 건. dayOfYear 는 2026년 기준 통일 좌표(월 경계를 넘는 주기 계산용).
struct SpendRecord: Codable, Equatable {
    let title: String
    let category: String
    let month: Int
    let day: Int
    let amount: Int
    /// 캘린더에 일정으로 잡히는 지출인지(false = 장보기·구독처럼 일정 없이 나가는 돈)
    let onCalendar: Bool
    /// 하루 마감에서 학습한 일정의 식별자. 같은 결제를 두 번 학습하지 않게 한다.
    let sourceEventID: UUID?

    init(title: String, category: String, month: Int, day: Int, amount: Int,
         onCalendar: Bool, sourceEventID: UUID? = nil) {
        self.title = title
        self.category = category
        self.month = month
        self.day = day
        self.amount = amount
        self.onCalendar = onCalendar
        self.sourceEventID = sourceEventID
    }

    var dayOfYear: Int { SpendHistory.dayOfYear(month: month, day: day) }
}

/// 과거 이력에서 뽑아낸 반복 소비 패턴
struct SpendPattern: Identifiable {
    let id = UUID()
    let key: String            // 패턴 이름("와드", "쿠팡 장보기")
    let category: String
    let symbol: String
    let onCalendar: Bool
    let records: [SpendRecord]
    let cadenceDays: Int       // 평균 주기(일)
    let cadenceSpread: Double  // 주기 편차 — 작을수록 규칙적
    let avgAmount: Int
    let low: Int
    let high: Int
    let lastDayOfYear: Int

    /// 주기가 얼마나 일정한지(0~1). 편차가 주기의 20% 이내면 높게 본다.
    var regularity: Double {
        guard cadenceDays > 0 else { return 0 }
        return max(0, min(1, 1 - cadenceSpread / Double(cadenceDays) / 0.5))
    }

    /// 표본 수·규칙성을 함께 반영한 신뢰도
    var confidence: Double {
        let sample = min(1.0, Double(records.count) / 4.0)
        return (0.45 + 0.35 * regularity + 0.2 * sample).rounded(toPlaces: 2)
    }

    /// "6주" / "10일" 처럼 읽기 좋은 주기 표현
    var cadenceLabel: String {
        if cadenceDays >= 13 && cadenceDays % 7 <= 2 { return "\(cadenceDays / 7)주" }
        if cadenceDays >= 26 { return "\(Int((Double(cadenceDays) / 30.0).rounded()))개월" }
        return "\(cadenceDays)일"
    }

    /// 다음 발생 예상일(2026 dayOfYear)
    var nextDayOfYear: Int { lastDayOfYear + cadenceDays }
}

/// 캘린더 일정 하나에 붙는 예측 결과
struct SpendPrediction {
    let amount: Int
    let low: Int
    let high: Int
    let confidence: Double
    let reason: String         // "성제님의 와드 방문 주기는 6주 정도였어요"
    let detail: String         // 근거가 된 과거 기록 요약
}

/// 캘린더에 없지만 주기상 곧 나갈 것으로 보이는 지출
struct UpcomingSpend: Identifiable {
    let id = UUID()
    let pattern: SpendPattern
    let expectedDay: Int       // 7월 며칠
    let amount: Int
    let reason: String
}

// MARK: - 이력 데이터

enum SpendHistory {

    /// 2026년 5~7월 초 지출 이력. 7월 캘린더 이전의 소비 패턴 원천이다.
    static let records: [SpendRecord] = [
        // 카페 — 서로 다른 일정이어도 같은 업종 표본으로 묶어 약속 금액을 추정한다.
        // 중앙값(10,000원·30,000원의 가운데 값)이 20,000원이라 고정 상수가 필요 없다.
        SpendRecord(title: "동네 커피", category: "카페", month: 5, day: 11, amount: 10_000, onCalendar: true),
        SpendRecord(title: "주말 카공", category: "카페", month: 6, day: 21, amount: 30_000, onCalendar: true),

        // 와드 — 6주 주기로 다녀온다
        SpendRecord(title: "와드", category: "모임", month: 5, day: 16, amount: 42_000, onCalendar: true),
        SpendRecord(title: "와드", category: "모임", month: 6, day: 27, amount: 38_000, onCalendar: true),

        // 쿠팡 장보기 — 캘린더에 없지만 10일마다 규칙적으로 나간다
        SpendRecord(title: "쿠팡 장보기", category: "생활", month: 5, day: 3, amount: 33_000, onCalendar: false),
        SpendRecord(title: "쿠팡 장보기", category: "생활", month: 5, day: 13, amount: 36_000, onCalendar: false),
        SpendRecord(title: "쿠팡 장보기", category: "생활", month: 5, day: 24, amount: 34_000, onCalendar: false),
        SpendRecord(title: "쿠팡 장보기", category: "생활", month: 6, day: 3, amount: 37_000, onCalendar: false),
        SpendRecord(title: "쿠팡 장보기", category: "생활", month: 6, day: 13, amount: 35_000, onCalendar: false),
        SpendRecord(title: "쿠팡 장보기", category: "생활", month: 6, day: 23, amount: 34_000, onCalendar: false),
        SpendRecord(title: "쿠팡 장보기", category: "생활", month: 7, day: 3, amount: 36_000, onCalendar: false),
        SpendRecord(title: "쿠팡 장보기", category: "생활", month: 7, day: 13, amount: 35_000, onCalendar: false),

        // 주말 데이트 — 격주 일요일, 7만원 안팎 (7/12 데이트가 이 주기의 연장선)
        SpendRecord(title: "주말 데이트", category: "데이트", month: 5, day: 17, amount: 68_000, onCalendar: true),
        SpendRecord(title: "주말 데이트", category: "데이트", month: 5, day: 31, amount: 72_000, onCalendar: true),
        SpendRecord(title: "주말 데이트", category: "데이트", month: 6, day: 14, amount: 65_000, onCalendar: true),
        SpendRecord(title: "주말 데이트", category: "데이트", month: 6, day: 28, amount: 75_000, onCalendar: true),

        // 미용실 — 7주 주기
        SpendRecord(title: "미용실", category: "자기관리", month: 5, day: 9, amount: 25_000, onCalendar: true),
        SpendRecord(title: "미용실", category: "자기관리", month: 6, day: 27, amount: 27_000, onCalendar: true),
    ]

    /// 하루 마감에서 사용자가 현금 결제로 확인한 개인 이력.
    /// 앱의 기존 호출부를 바꾸지 않고도 일정 추가·챗봇·반복 예측이 같은 최신 표본을 보도록
    /// 메모리의 단일 원천으로 둔다. 실제 영속 원천은 보호된 LocalStore의 PersistedState다.
    private(set) static var learnedRecords: [SpendRecord] = []

    static var allRecords: [SpendRecord] { records + learnedRecords }

    static func replaceLearnedRecords(_ records: [SpendRecord]) {
        learnedRecords = records.filter(isValid)
    }

    /// 패턴별 아이콘
    private static let symbols: [String: String] = [
        "와드": "person.2",
        "쿠팡 장보기": "cart",
        "주말 데이트": "heart",
        "미용실": "scissors",
    ]

    /// 2026년 월별 누적 일수 (평년)
    private static let cumulative = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]

    static func dayOfYear(month: Int, day: Int) -> Int { cumulative[month - 1] + day }

    private static func isValid(_ record: SpendRecord) -> Bool {
        guard record.amount > 0, record.amount <= 100_000_000,
              (1...12).contains(record.month), record.day > 0 else { return false }
        var components = DateComponents()
        components.year = 2026
        components.month = record.month
        components.day = record.day
        guard let date = Calendar(identifier: .gregorian).date(from: components) else { return false }
        return Calendar(identifier: .gregorian).component(.month, from: date) == record.month
            && Calendar(identifier: .gregorian).component(.day, from: date) == record.day
    }

    // MARK: - 패턴 탐지

    /// 같은 제목의 기록을 묶어 주기·평균 금액을 계산한다. 2회 이상만 패턴으로 인정.
    static var patterns: [SpendPattern] { patterns(in: allRecords) }

    static func patterns(in records: [SpendRecord]) -> [SpendPattern] {
        Dictionary(grouping: records.filter(isValid), by: \.title)
            .compactMap { title, group -> SpendPattern? in
                let sorted = group.sorted { $0.dayOfYear < $1.dayOfYear }
                guard sorted.count >= 2 else { return nil }

                let gaps = zip(sorted, sorted.dropFirst()).map { $1.dayOfYear - $0.dayOfYear }
                let cadence = Int((Double(gaps.reduce(0, +)) / Double(gaps.count)).rounded())
                let mean = Double(gaps.reduce(0, +)) / Double(gaps.count)
                let spread = gaps.count > 1
                    ? (gaps.map { pow(Double($0) - mean, 2) }.reduce(0, +) / Double(gaps.count)).squareRoot()
                    : 0

                let amounts = sorted.map(\.amount)
                return SpendPattern(
                    key: title,
                    category: sorted[0].category,
                    symbol: symbols[title] ?? "calendar",
                    onCalendar: sorted[0].onCalendar,
                    records: sorted,
                    cadenceDays: max(cadence, 1),
                    cadenceSpread: spread,
                    avgAmount: medianAmount(amounts),
                    low: amounts.min() ?? 0,
                    high: amounts.max() ?? 0,
                    lastDayOfYear: sorted.last!.dayOfYear
                )
            }
            .sorted { $0.key < $1.key }
    }

    // MARK: - 일정 제목 → 예측

    /// 캘린더 일정 제목과 같은 패턴을 찾아 금액을 예측한다.
    static func predict(title: String, in records: [SpendRecord]? = nil) -> SpendPrediction? {
        let t = title.replacingOccurrences(of: " ", with: "")
        let candidates = records.map { patterns(in: $0) } ?? patterns
        guard let p = candidates.first(where: {
            let key = $0.key.replacingOccurrences(of: " ", with: "")
            return t.contains(key) || key.contains(t)
        }) else { return nil }

        return SpendPrediction(
            amount: p.avgAmount,
            low: p.low,
            high: p.high,
            confidence: p.confidence,
            reason: reason(for: p),
            detail: recordSummary(p)
        )
    }

    /// 일정 제목과 매칭되는 패턴의 카테고리
    static func category(for title: String, in records: [SpendRecord]? = nil) -> String? {
        let t = title.replacingOccurrences(of: " ", with: "")
        let candidates = records.map { patterns(in: $0) } ?? patterns
        return candidates.first {
            let key = $0.key.replacingOccurrences(of: " ", with: "")
            return t.contains(key) || key.contains(t)
        }?.category
    }

    /// 같은 업종 표본이 최소 2건일 때만 개인 대표값을 만든다.
    /// 평균은 한 번의 큰 결제에 쉽게 흔들리므로 중앙값을 쓰고, 범위는 실제 관측 최솟값·최댓값을 보여준다.
    static func representative(for category: String,
                               in records: [SpendRecord]? = nil)
        -> (amount: Int, low: Int, high: Int, sampleCount: Int)? {
        let source = records ?? allRecords
        let amounts = source
            .filter { isValid($0) && $0.category == category }
            .map(\.amount)
            .sorted()
        guard amounts.count >= 2, let low = amounts.first, let high = amounts.last else { return nil }
        return (medianAmount(amounts), low, high, amounts.count)
    }

    /// 패턴별 근거 문장 — 주기가 규칙적이면 주기를, 아니면 평균 금액을 앞세운다.
    static func reason(for p: SpendPattern) -> String {
        if p.regularity >= 0.6 {
            return "성제님의 \(p.key) 주기는 \(p.cadenceLabel) 정도였어요."
        }
        return "지난 \(p.records.count)건의 \(p.key) 결제 중앙값은 \(formatWon(p.avgAmount))이에요."
    }

    /// "5월 16일 42,000원 · 6월 27일 38,000원"
    static func recordSummary(_ p: SpendPattern) -> String {
        p.records.suffix(3)
            .map { "\($0.month)월 \($0.day)일 \(formatWon($0.amount))" }
            .joined(separator: " · ")
    }

    // MARK: - 캘린더에 없는 다가올 지출

    /// `from`~`to`(7월 며칠) 사이에 주기가 돌아오는, 캘린더에 없는 지출을 찾는다.
    static func upcoming(from: Int, to: Int, excludingTitles taken: Set<String>) -> [UpcomingSpend] {
        let julyStart = dayOfYear(month: 7, day: 1)
        return patterns.compactMap { p -> UpcomingSpend? in
            // 그 구간 캘린더에 이미 같은 일정이 있으면 예측하지 않는다(중복 계상 방지).
            guard !taken.contains(p.key) else { return nil }

            // 마지막 발생부터 주기를 더해가며 구간 안에 들어오는 첫 날을 찾는다
            var next = p.nextDayOfYear
            while next < julyStart + from - 1 { next += p.cadenceDays }
            let day = next - julyStart + 1
            guard day >= from, day <= to else { return nil }

            return UpcomingSpend(
                pattern: p, expectedDay: day, amount: p.avgAmount,
                reason: "개인 기록 \(p.records.count)건에서 \(p.cadenceLabel) 주기·중앙값 \(formatWon(p.avgAmount))이 보여요."
            )
        }
        .sorted { $0.expectedDay < $1.expectedDay }
    }
}

private func roundToThousand(_ v: Int) -> Int { Int((Double(v) / 1_000).rounded()) * 1_000 }

/// 짝수 표본은 가운데 두 값의 평균을 사용한다. 천원 단위 반올림은 지나친 정밀도를 피한다.
private func medianAmount(_ values: [Int]) -> Int {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    let raw = sorted.count.isMultiple(of: 2)
        ? (sorted[middle - 1] + sorted[middle]) / 2
        : sorted[middle]
    return roundToThousand(raw)
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let d = pow(10.0, Double(places))
        return (self * d).rounded() / d
    }
}
