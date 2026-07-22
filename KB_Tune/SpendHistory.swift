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
struct SpendRecord {
    let title: String
    let category: String
    let month: Int
    let day: Int
    let amount: Int
    /// 캘린더에 일정으로 잡히는 지출인지(false = 장보기·구독처럼 일정 없이 나가는 돈)
    let onCalendar: Bool

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

    // MARK: - 패턴 탐지

    /// 같은 제목의 기록을 묶어 주기·평균 금액을 계산한다. 2회 이상만 패턴으로 인정.
    static let patterns: [SpendPattern] = {
        Dictionary(grouping: records, by: \.title)
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
                    avgAmount: roundToThousand(amounts.reduce(0, +) / amounts.count),
                    low: amounts.min() ?? 0,
                    high: amounts.max() ?? 0,
                    lastDayOfYear: sorted.last!.dayOfYear
                )
            }
            .sorted { $0.key < $1.key }
    }()

    // MARK: - 일정 제목 → 예측

    /// 캘린더 일정 제목과 같은 패턴을 찾아 금액을 예측한다.
    static func predict(title: String) -> SpendPrediction? {
        let t = title.replacingOccurrences(of: " ", with: "")
        guard let p = patterns.first(where: {
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
    static func category(for title: String) -> String? {
        let t = title.replacingOccurrences(of: " ", with: "")
        return patterns.first {
            let key = $0.key.replacingOccurrences(of: " ", with: "")
            return t.contains(key) || key.contains(t)
        }?.category
    }

    /// 패턴별 근거 문장 — 주기가 규칙적이면 주기를, 아니면 평균 금액을 앞세운다.
    static func reason(for p: SpendPattern) -> String {
        if p.regularity >= 0.6 {
            return "성제님의 \(p.key) 주기는 \(p.cadenceLabel) 정도였어요."
        }
        return "지난 두 달 \(p.key)에 평균 \(formatWon(p.avgAmount))을 썼어요."
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
                reason: "\(p.cadenceLabel)에 한 번씩 평균 \(formatWon(p.avgAmount))을 써요."
            )
        }
        .sorted { $0.expectedDay < $1.expectedDay }
    }
}

private func roundToThousand(_ v: Int) -> Int { Int((Double(v) / 1_000).rounded()) * 1_000 }

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let d = pow(10.0, Double(places))
        return (self * d).rounded() / d
    }
}
