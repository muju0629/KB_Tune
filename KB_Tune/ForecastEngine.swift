//
//  ForecastEngine.swift
//  KB_Tune
//
//  Python에서 검증한 LightGBM 트리를 기기 안에서 그대로 실행한다.
//  원거래·피처·예측값은 서버로 보내지 않는다.
//

import Foundation

struct ForecastCategoryResult: Equatable, Identifiable {
    var id: String { category }
    let category: String
    let centralAmount: Int
    let safeAmount: Int
    let occurrenceProbability: Double
    let expectedDay: Int
}

struct WeeklyForecastResult: Equatable {
    let modelVersion: String
    let featureVersion: String
    let categories: [ForecastCategoryResult]

    var centralTotal: Int { categories.reduce(0) { $0 + $1.centralAmount } }
    var safeTotal: Int { categories.reduce(0) { $0 + $1.safeAmount } }
}

private struct ForecastModelFile: Decodable {
    let modelVersion: String
    let featureVersion: String
    let categories: [String]
    let amount: AmountSection
    let hazard: HazardSection

    struct AmountSection: Decodable {
        let models: [String: CompactTreeModel]
        let metadata: AmountMetadata
    }

    struct HazardSection: Decodable {
        let models: [String: CompactTreeModel]
        let metadata: HazardMetadata
    }

    struct AmountMetadata: Decodable {
        let biasFactor: Double
        let populationAmount: [String: Double]
        let populationOccurrence: [String: Double]
    }

    struct HazardMetadata: Decodable {
        let calibrators: [String: ProbabilityCalibration]
        let populationAmount: [String: Double]
        let populationOccurrence: [String: Double]
    }
}

struct ProbabilityCalibration: Decodable, Equatable {
    let coefficient: Double
    let intercept: Double
}

struct CompactTreeNode: Decodable, Equatable {
    let f: Int?
    let t: Double?
    let l: Int?
    let r: Int?
    let d: Bool?
    let v: Double?
}

struct CompactTreeModel: Decodable, Equatable {
    let features: [String]
    let transform: String
    let trees: [[CompactTreeNode]]

    func predict(_ row: [String: Double]) -> Double {
        let values = features.map { row[$0] ?? 0 }
        var total = 0.0
        for tree in trees {
            var index = 0
            while tree.indices.contains(index), tree[index].v == nil {
                let node = tree[index]
                guard let feature = node.f, values.indices.contains(feature),
                      let threshold = node.t, let left = node.l, let right = node.r else { break }
                let value = values[feature]
                let goLeft = value.isFinite ? value <= threshold : (node.d ?? true)
                index = goLeft ? left : right
            }
            if tree.indices.contains(index) { total += tree[index].v ?? 0 }
        }
        if transform == "sigmoid" { return 1 / (1 + exp(-total)) }
        return total
    }
}

enum ForecastEngine {
    static let fallbackModelVersion = "forecast-unavailable"
    private static let calendarSensitiveCategories: Set<String> = ["모임", "데이트"]

    private static let file: ForecastModelFile? = {
        guard let url = Bundle.main.url(forResource: "ForecastModels", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ForecastModelFile.self, from: data)
    }()

    static var modelVersion: String { file?.modelVersion ?? fallbackModelVersion }
    static var featureVersion: String { file?.featureVersion ?? "forecast-feature-v1" }
    static var isAvailable: Bool { file != nil }

    static func weekly(
        records: [SpendRecord],
        calendarDays: [PlanDay],
        startDay: Int,
        useCalendar: Bool
    ) -> WeeklyForecastResult? {
        guard let file,
              let occurrence = file.amount.models["amountOccurrence"],
              let conditional = file.amount.models["amountConditionalLog"],
              let q75 = file.amount.models["safeQ75"],
              let plainHazard = file.hazard.models["hazard"],
              let calendarHazard = file.hazard.models["hazardCalendar"],
              let plainCalibration = file.hazard.metadata.calibrators["hazard"],
              let calendarCalibration = file.hazard.metadata.calibrators["hazardCalendar"]
        else { return nil }

        let transactions = transactions(records: records, calendarDays: calendarDays,
                                        before: startDay)
        let startOrdinal = ordinal(for: startDay)
        // 일정 날짜·유형·금액만 사용하며 제목 원문은 이 계약에 들어오지 않는다.
        let calendar = useCalendar ? futureCalendar(calendarDays, startDay: startDay) : []
        let amountStats = PopulationStats(
            amount: file.amount.metadata.populationAmount,
            occurrence: file.amount.metadata.populationOccurrence
        )
        let hazardStats = PopulationStats(
            amount: file.hazard.metadata.populationAmount,
            occurrence: file.hazard.metadata.populationOccurrence
        )

        let results = file.categories.map { category -> ForecastCategoryResult in
            // 홀드아웃에서 캘린더 이득이 확인된 일정형 범주에만 calendar 모델을 쓴다.
            let usesCalendarHazard = useCalendar && calendarSensitiveCategories.contains(category)
            let hazard = usesCalendarHazard ? calendarHazard : plainHazard
            let calibration = usesCalendarHazard ? calendarCalibration : plainCalibration
            let amountRow = baseFeatures(category: category, startOrdinal: startOrdinal,
                                         transactions: transactions, calendar: calendar,
                                         stats: amountStats, categories: file.categories)
            let p = occurrence.predict(amountRow).clamped(to: 0.01...0.99)
            let conditionalAmount = max(0, exp(conditional.predict(amountRow)) - 1)
            let central = p * conditionalAmount * file.amount.metadata.biasFactor
            let safe = max(0, q75.predict(amountRow))

            let history = historyFeatures(category: category, startOrdinal: startOrdinal,
                                          transactions: transactions)
            let calendarOrdinals = Set(calendar.filter { $0.category == category }.map(\.ordinal))
            var hazards: [Double] = []
            for offset in 0..<7 {
                var row = baseFeatures(category: category, startOrdinal: startOrdinal,
                                       transactions: transactions, calendar: calendar,
                                       stats: hazardStats, categories: file.categories)
                let day = startOrdinal + offset
                let elapsed = history.lastOrdinal.map { day - $0 } ?? 365
                row["weekday_sin"] = sin(2 * .pi * Double(offset) / 7)
                row["weekday_cos"] = cos(2 * .pi * Double(offset) / 7)
                row["days_since_last"] = Double(elapsed)
                row["median_gap"] = history.medianGap
                row["gap_deviation"] = abs(Double(elapsed) - history.medianGap)
                row["gap_cv"] = history.gapCV
                row["history_event_count"] = Double(history.eventCount)
                row["modal_weekday_match"] = history.modalWeekday == offset ? 1 : 0
                row["calendar_today"] = calendarOrdinals.contains(day) ? 1 : 0
                row["calendar_near"] = calendarOrdinals.contains { abs($0 - day) <= 1 } ? 1 : 0
                hazards.append(hazard.predict(row).clamped(to: 0.001...0.999))
            }
            var survival = 1.0
            var mass: [Double] = []
            for value in hazards {
                mass.append(survival * value)
                survival *= 1 - value
            }
            let rawProbability = (1 - survival).clamped(to: 0.001...0.999)
            let logit = log(rawProbability / (1 - rawProbability))
            let probability = 1 / (1 + exp(-(calibration.intercept
                                              + calibration.coefficient * logit)))
            let offset = mass.enumerated().max { $0.element < $1.element }?.offset ?? 0
            return ForecastCategoryResult(
                category: category,
                centralAmount: roundToThousand(central),
                safeAmount: roundToThousand(safe),
                occurrenceProbability: probability.clamped(to: 0...1),
                expectedDay: min(startDay + offset, DemoClock.lastDay)
            )
        }
        return WeeklyForecastResult(modelVersion: file.modelVersion,
                                    featureVersion: file.featureVersion,
                                    categories: results)
    }

    // 테스트는 번들에 든 Python 고정 입력을 이 함수로 직접 대조한다.
    static func bundledModel(named name: String) -> CompactTreeModel? {
        file?.amount.models[name] ?? file?.hazard.models[name]
    }

    static func calibration(named name: String) -> ProbabilityCalibration? {
        file?.hazard.metadata.calibrators[name]
    }

    static func centralPrediction(features: [String: Double]) -> (central: Double, safe: Double)? {
        guard let file,
              let occurrence = file.amount.models["amountOccurrence"],
              let conditional = file.amount.models["amountConditionalLog"],
              let safe = file.amount.models["safeQ75"] else { return nil }
        let p = occurrence.predict(features)
        let amount = max(0, exp(conditional.predict(features)) - 1)
        return (p * amount * file.amount.metadata.biasFactor,
                max(0, safe.predict(features)))
    }

    static func hazardPrediction(rows: [[String: Double]], useCalendar: Bool)
        -> (probability: Double, offset: Int)? {
        let name = useCalendar ? "hazardCalendar" : "hazard"
        guard let file, let model = file.hazard.models[name],
              let calibration = file.hazard.metadata.calibrators[name],
              !rows.isEmpty else { return nil }
        let hazards = rows.map { model.predict($0).clamped(to: 0.001...0.999) }
        var survival = 1.0
        var mass: [Double] = []
        for value in hazards {
            mass.append(survival * value)
            survival *= 1 - value
        }
        let raw = (1 - survival).clamped(to: 0.001...0.999)
        let logit = log(raw / (1 - raw))
        let probability = 1 / (1 + exp(-(calibration.intercept
                                         + calibration.coefficient * logit)))
        return (probability, mass.enumerated().max { $0.element < $1.element }?.offset ?? 0)
    }

    private struct Transaction {
        let ordinal: Int
        let category: String
        let amount: Double
    }

    private struct CalendarItem {
        let ordinal: Int
        let category: String
    }

    private struct PopulationStats {
        let amount: [String: Double]
        let occurrence: [String: Double]
    }

    private struct HistorySummary {
        let lastOrdinal: Int?
        let medianGap: Double
        let gapCV: Double
        let eventCount: Int
        let modalWeekday: Int
    }

    private static func ordinal(for serialDay: Int) -> Int {
        SpendHistory.dayOfYear(month: DemoClock.month(of: serialDay),
                               day: DemoClock.dayOfMonth(of: serialDay)) - 1
    }

    private static func transactions(records: [SpendRecord], calendarDays: [PlanDay],
                                     before startDay: Int) -> [Transaction] {
        var output = records.map {
            Transaction(ordinal: $0.dayOfYear - 1, category: $0.category,
                        amount: Double($0.amount))
        }
        output += calendarDays
            .filter { $0.dayNumber < startDay }
            .flatMap { day in
                day.events.compactMap { event in
                    guard event.state == .confirmed, event.amount > 0 else { return nil }
                    return Transaction(ordinal: ordinal(for: day.dayNumber),
                                       category: event.category, amount: Double(event.amount))
                }
            }
        return output
    }

    private static func futureCalendar(_ days: [PlanDay], startDay: Int) -> [CalendarItem] {
        let end = min(startDay + 6, DemoClock.lastDay)
        return days.filter { $0.dayNumber >= startDay && $0.dayNumber <= end }
            .flatMap { day in
                day.events.compactMap { event in
                    guard event.amount > 0 else { return nil }
                    return CalendarItem(ordinal: ordinal(for: day.dayNumber),
                                        category: event.category)
                }
            }
    }

    private static func baseFeatures(
        category: String,
        startOrdinal: Int,
        transactions: [Transaction],
        calendar: [CalendarItem],
        stats: PopulationStats,
        categories: [String]
    ) -> [String: Double] {
        let historyStart = startOrdinal - 56
        var amounts = [Double](repeating: 0, count: 8)
        var counts = [Double](repeating: 0, count: 8)
        var totals = [Double](repeating: 0, count: 8)
        for item in transactions where item.ordinal >= historyStart && item.ordinal < startOrdinal {
            let index = min(7, max(0, (item.ordinal - historyStart) / 7))
            totals[index] += item.amount
            if item.category == category {
                amounts[index] += item.amount
                counts[index] += 1
            }
        }
        let positives = amounts.filter { $0 > 0 }
        let pastDays = transactions
            .filter { $0.category == category && $0.ordinal < startOrdinal }
            .map(\.ordinal).sorted()
        let calendarCount = Double(calendar.filter { $0.category == category }.count)
        let populationAmount = stats.amount[category] ?? 0
        var row: [String: Double] = [
            "amount_mean": amounts.mean,
            "amount_median": amounts.median,
            "positive_mean": positives.isEmpty ? populationAmount : positives.mean,
            "amount_std": amounts.standardDeviation,
            "occur_rate": Double(amounts.filter { $0 > 0 }.count) / 8,
            "count_mean": counts.mean,
            "last_amount": amounts.last ?? 0,
            "elapsed_days": Double(pastDays.last.map { startOrdinal - $0 } ?? 365),
            "total_mean": totals.mean,
            "total_std": totals.standardDeviation,
            "category_share": amounts.reduce(0, +) / max(totals.reduce(0, +), 1),
            "calendar_count": calendarCount,
            "calendar_expected": calendarCount * populationAmount * 0.90,
            "population_amount": populationAmount,
            "population_occurrence": stats.occurrence[category] ?? 0,
        ]
        for item in categories { row["category_\(item)"] = item == category ? 1 : 0 }
        return row
    }

    private static func historyFeatures(category: String, startOrdinal: Int,
                                        transactions: [Transaction]) -> HistorySummary {
        let days = transactions.filter { $0.category == category && $0.ordinal < startOrdinal }
            .map(\.ordinal).sorted()
        let recent = days.filter { $0 >= startOrdinal - 56 }
        let tail = Array(days.suffix(9))
        let gaps = zip(tail, tail.dropFirst()).map { Double($1 - $0) }
        let median = gaps.isEmpty ? 28 : gaps.median
        let cv = gaps.count >= 2 ? gaps.standardDeviation / max(gaps.mean, 1) : 1
        // 합성 학습 좌표의 0은 월요일이다. 2026-01-01(목)을 같은 좌표로 옮긴다.
        let weekdayCounts = Dictionary(grouping: days.map { ($0 + 3) % 7 }, by: { $0 })
        let modal = weekdayCounts.max {
            if $0.value.count == $1.value.count { return $0.key > $1.key }
            return $0.value.count < $1.value.count
        }?.key ?? 0
        return HistorySummary(lastOrdinal: days.last, medianGap: median, gapCV: cv,
                              eventCount: recent.count, modalWeekday: modal)
    }

    private static func roundToThousand(_ value: Double) -> Int {
        Int((max(0, value) / 1_000).rounded()) * 1_000
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension Array where Element == Double {
    var mean: Double { isEmpty ? 0 : reduce(0, +) / Double(count) }
    var median: Double {
        guard !isEmpty else { return 0 }
        let values = sorted()
        let middle = count / 2
        return count.isMultiple(of: 2)
            ? (values[middle - 1] + values[middle]) / 2
            : values[middle]
    }
    var standardDeviation: Double {
        guard !isEmpty else { return 0 }
        let average = mean
        return (reduce(0) { $0 + pow($1 - average, 2) } / Double(count)).squareRoot()
    }
}
