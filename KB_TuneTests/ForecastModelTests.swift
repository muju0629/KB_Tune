import Foundation
import Testing
@testable import KB_Tune

private struct ForecastGoldenFile: Decodable {
    let modelVersion: String
    let amount: [AmountFixture]
    let hazard: [HazardFixture]

    struct AmountFixture: Decodable {
        let features: [String: Double]
        let central: Double
        let safe: Double
    }

    struct HazardFixture: Decodable {
        let rows: [[String: Double]]
        let hazard: Expected
        let hazardCalendar: Expected
    }

    struct Expected: Decodable {
        let probability: Double
        let offset: Int
    }
}

@Suite(.serialized)
struct ForecastModelTests {
    private func fixtures() throws -> ForecastGoldenFile {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("ForecastGolden.json")
        return try JSONDecoder().decode(ForecastGoldenFile.self,
                                        from: Data(contentsOf: url))
    }

    @Test func pythonAndSwiftAmountTreesHaveGoldenParity() throws {
        let golden = try fixtures()
        #expect(ForecastEngine.isAvailable)
        #expect(ForecastEngine.modelVersion == golden.modelVersion)

        for item in golden.amount {
            let actual = try #require(ForecastEngine.centralPrediction(features: item.features))
            #expect(abs(actual.central - item.central) < max(0.01, item.central * 1e-9))
            #expect(abs(actual.safe - item.safe) < max(0.01, item.safe * 1e-9))
        }
    }

    @Test func pythonAndSwiftHazardTreesHaveGoldenParity() throws {
        let golden = try fixtures()
        for item in golden.hazard {
            let plain = try #require(ForecastEngine.hazardPrediction(
                rows: item.rows, useCalendar: false
            ))
            let calendar = try #require(ForecastEngine.hazardPrediction(
                rows: item.rows, useCalendar: true
            ))
            #expect(abs(plain.probability - item.hazard.probability) < 1e-9)
            #expect(plain.offset == item.hazard.offset)
            #expect(abs(calendar.probability - item.hazardCalendar.probability) < 1e-9)
            #expect(calendar.offset == item.hazardCalendar.offset)
        }
    }

    @Test func appForecastSeparatesCentralAndSafeAmountsOnDevice() throws {
        DemoClock.fixedToday = 22
        defer { DemoClock.fixedToday = nil }
        let model = AppModel()
        let forecast = try #require(model.weeklyForecast)

        #expect(forecast.modelVersion == "forecast-synth-v1-2026-07-30")
        #expect(forecast.featureVersion == "forecast-feature-v1")
        #expect(forecast.categories.count == 7)
        #expect(forecast.centralTotal > 0)
        #expect(forecast.safeTotal > 0)
        #expect(forecast.categories.allSatisfy { (0...1).contains($0.occurrenceProbability) })
        #expect(forecast.categories.allSatisfy { $0.expectedDay >= model.currentWeekRange.lowerBound })
    }

    @Test func calendarHazardIsLimitedToValidatedScheduledCategories() throws {
        DemoClock.fixedToday = 22
        defer { DemoClock.fixedToday = nil }
        let model = AppModel()
        let plain = try #require(ForecastEngine.weekly(
            records: SpendHistory.records, calendarDays: model.calendarDays,
            startDay: model.currentWeekRange.lowerBound, useCalendar: false
        ))
        let calendar = try #require(ForecastEngine.weekly(
            records: SpendHistory.records, calendarDays: model.calendarDays,
            startDay: model.currentWeekRange.lowerBound, useCalendar: true
        ))
        let scheduled: Set<String> = ["모임", "데이트"]

        for item in plain.categories where !scheduled.contains(item.category) {
            let compared = try #require(calendar.categories.first { $0.category == item.category })
            #expect(compared.occurrenceProbability == item.occurrenceProbability)
        }
    }
}
