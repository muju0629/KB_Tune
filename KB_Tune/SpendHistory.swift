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

        // 와드 — 미용실. 6주 주기이고 금액이 거의 고정이다.
        // 카테고리가 "모임"이면 사전분포의 금액 변동(σ²=0.18)이 과대해서 80% 구간이
        // 24,026~66,452원까지 벌어진다. 자기관리(σ²=0.02)에서는 33,199~48,076원이다.
        // 관측 주기 42일도 자기관리 사전값(42일)과 일치한다.
        SpendRecord(title: "와드", category: "자기관리", month: 5, day: 16, amount: 42_000, onCalendar: true),
        SpendRecord(title: "와드", category: "자기관리", month: 6, day: 27, amount: 38_000, onCalendar: true),

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
        "와드": "scissors",
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
    ///
    /// 구간은 관측 최솟값~최댓값이 아니라 **사후분포의 80% 구간**이다.
    /// 관측 범위는 표본이 적을 때 지나치게 좁아진다 — 2건이면 두 값 사이가 전부라
    /// "80% 구간"이라 부를 수 없다. 벤치마크에서 그 방식의 실제 커버리지가 65.7%로
    /// 측정됐다(tools/forecast_bench/results/METHOD.md §4.4).
    static func predict(title: String, in records: [SpendRecord]? = nil) -> SpendPrediction? {
        let t = title.replacingOccurrences(of: " ", with: "")
        let candidates = records.map { patterns(in: $0) } ?? patterns
        guard let p = candidates.first(where: {
            let key = $0.key.replacingOccurrences(of: " ", with: "")
            return t.contains(key) || key.contains(t)
        }) else { return nil }

        let posterior = posteriorAmount(for: p)
        return SpendPrediction(
            amount: posterior.amount,
            low: posterior.low,
            high: posterior.high,
            confidence: posterior.confidence,
            reason: reason(for: p),
            detail: recordSummary(p)
        )
    }

    /// 이 패턴이 고정 지출인가. 관측에서 자동 판정한다. 표본 2건 미만이면 nil.
    static func isFixedAmount(for p: SpendPattern) -> Bool? {
        SpendModel.isFixedAmount(of: p.records.map(\.amount))
    }

    /// 패턴의 사후분포 금액·구간·신뢰도. 개인 이력이 적으면 인구 사전분포가 받쳐준다.
    ///
    /// 신뢰도는 휴리스틱이 아니라 **사후분포의 폭에서 나온다** — 구간이 좁을수록 높다.
    /// 관측이 쌓이면 모수 불확실성 항만 줄고 개인 내 변동 항은 남으므로 1 로 수렴하지
    /// 않는다. 같은 사람도 같은 일정에 매번 같은 금액을 쓰지 않는다.
    static func posteriorAmount(for p: SpendPattern, asOf today: Int? = nil)
        -> (amount: Int, low: Int, high: Int, confidence: Double) {
        let day = today ?? dayOfYear(month: 7, day: DemoClock.today)
        let prior = SpendPriors.prior(for: p.category, meanAmount: Double(p.avgAmount))
        let tracker = tracker(from: p.records, asOfDayOfYear: day, prior: prior)
        let a = SpendModel.amount(tracker.slow, prior)
        // 같은 금액이 반복되는 지출에 구간을 붙이면 안 된다. 구독료가 매달 3,900원인데
        // "2,900~5,200원" 이라고 보여주면 모델이 모르는 것처럼 보인다.
        if SpendModel.isFixedAmount(of: p.records.map(\.amount)) == true {
            let mode = repeatedAmount(p.records.map(\.amount))
            return (mode, mode, mode, 0.9)
        }

        // 구간 폭이 중앙값의 몇 배인지로 신뢰도를 낸다. 폭이 좁을수록 확신이 크다.
        let spread = a.median > 0 ? (a.high - a.low) / a.median : 2
        let confidence = max(0.4, min(0.9, 1.15 - spread / 2)).rounded(toPlaces: 2)

        return (roundToThousand(Int(a.median.rounded())),
                roundToThousand(Int(a.low.rounded())),
                roundToThousand(Int(a.high.rounded())),
                confidence)
    }

    /// 가장 많이 반복된 금액(천원 단위). 동수면 큰 쪽 — 예산은 넉넉히 잡는 편이 안전하다.
    private static func repeatedAmount(_ amounts: [Int]) -> Int {
        var counts: [Int: Int] = [:]
        for a in amounts { counts[roundToThousand(a), default: 0] += 1 }
        let best = counts.max { ($0.value, $0.key) < ($1.value, $1.key) }
        return best?.key ?? roundToThousand(amounts.first ?? 0)
    }

    /// 다음 `days` 일 안에 이 패턴이 발생할 확률. 추천 임계값을 여기 건다.
    ///
    /// 규칙적인 카테고리에서만 경과일이 정보를 준다. 카페처럼 무기억인 카테고리는
    /// 어제 갔든 두 달 전이든 확률이 같다 — 그런 카테고리에 "갈 때 됐어요" 알림을
    /// 띄우면 매일 뜨고 쓸모없다.
    static func probability(of p: SpendPattern, within days: Int, asOf today: Int? = nil) -> Double {
        let day = today ?? dayOfYear(month: 7, day: DemoClock.today)
        let prior = SpendPriors.prior(for: p.category, meanAmount: Double(p.avgAmount))
        let tracker = tracker(from: p.records, asOfDayOfYear: day, prior: prior)
        return SpendModel.probability(tracker.slow, SpendModel.learned(tracker.slow, prior),
                                      within: Double(days))
    }

    /// 이 습관을 그만둔 것 같은가. 예산에서 자동으로 빼는 데 쓰지 말 것 —
    /// 사용자에게 물어보는 트리거다. 한 주 안 갔다고 술값을 빼면 다음 주에 초과한다.
    static func quitSignal(for p: SpendPattern, asOf today: Int? = nil) -> Double {
        let day = today ?? dayOfYear(month: 7, day: DemoClock.today)
        let prior = SpendPriors.prior(for: p.category, meanAmount: Double(p.avgAmount))
        let tracker = tracker(from: p.records, asOfDayOfYear: day, prior: prior)
        return tracker.quitSignal(prior)
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


// MARK: - 이력 → 추정기

extension SpendHistory {

    /// 같은 패턴의 과거 기록으로 추정기를 채운다.
    ///
    /// 간격은 **실제 발생일의 차이**를 쓴다. 건수에서 만들어내지 않는다 —
    /// 균등 분할하면 분산이 인위적으로 줄어 규칙성이 부풀려지고 종료 판정이
    /// 오작동한다(파이썬 검증에서 카페가 1.0 대신 1.7 로 추정됐다).
    ///
    /// `SpendModel` 은 `SpendRecord` 를 모른다 — 그래야 단독 컴파일해서
    /// 파이썬 원본과 수치를 대조할 수 있다.
    static func tracker(from records: [SpendRecord], asOfDayOfYear today: Int,
                        prior: SpendPrior) -> SpendTracker {
        let sorted = records.sorted { $0.dayOfYear < $1.dayOfYear }
        var t = SpendTracker()
        guard let first = sorted.first else { return t }

        var previous = first.dayOfYear
        for (i, r) in sorted.enumerated() {
            let gap = i == 0 ? [] : [Double(r.dayOfYear - previous)]
            let span = i == 0 ? 1.0 : Double(r.dayOfYear - previous)
            t.update(count: 1, totalAmount: Double(r.amount), days: span,
                     prior: prior, gaps: gap)
            previous = r.dayOfYear
        }
        // 마지막 발생 이후 오늘까지의 공백. 종료 판정과 경과일 조건부 확률에 쓴다.
        let idle = Double(max(today - previous, 0))
        if idle > 0 {
            t.update(count: 0, totalAmount: 0, days: idle, prior: prior)
        }
        return t
    }

    /// 캘린더에 없는 반복 지출(장보기·구독 등)의 `days` 일 총액 분포.
    ///
    /// `BudgetEngine.spendSigma` 의 재량지출 항을 대체한다. 닫힌 공식은
    /// "하루 7,500원 × 남은일수" 라는 데모 가정과 발생률 불확실성 CV=1.0 을 쓰는데,
    /// 그건 개인 이력이 없을 때의 무지를 표현한 값이다. 이력이 있으면 카테고리별
    /// 사후분포를 합성해서 실제 산포를 쓸 수 있다 — 같은 모델의 더 좋은 근사다.
    ///
    /// 캘린더에 잡히는 패턴은 제외한다. 그건 확정 일정 금액 항에서 이미 세고 있어
    /// 여기서 또 더하면 이중 계상이다.
    static func offCalendarTotal(days: Double, draws: Int = 400,
                                 asOf today: Int? = nil) -> [Double] {
        let day = today ?? dayOfYear(month: 7, day: DemoClock.today)
        let targets = patterns.filter { !$0.onCalendar }
        guard !targets.isEmpty else { return [] }

        var sums = [Double](repeating: 0, count: draws)
        for (i, p) in targets.enumerated() {
            let prior = SpendPriors.prior(for: p.category, meanAmount: Double(p.avgAmount))
            let t = tracker(from: p.records, asOfDayOfYear: day, prior: prior)
            // 패턴마다 시드를 달리 준다 — 같은 시드면 표본이 같이 움직여 산포가 과대해진다.
            let s = SpendModel.sampleTotal(t.slow, prior, days: days,
                                           draws: draws, seed: UInt64(41 + i * 7919))
            for j in 0..<draws { sums[j] += s[j] }
        }
        return sums
    }

    /// 캘린더 밖 지출의 기간 분산. 이력이 없으면 nil — 호출부가 닫힌 공식으로 떨어진다.
    static func offCalendarVariance(days: Double, asOf today: Int? = nil) -> Double? {
        let s = offCalendarTotal(days: days, asOf: today)
        guard s.count > 1 else { return nil }
        let mean = s.reduce(0, +) / Double(s.count)
        let v = s.reduce(0) { $0 + pow($1 - mean, 2) } / Double(s.count - 1)
        return v > 0 ? v : nil
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
