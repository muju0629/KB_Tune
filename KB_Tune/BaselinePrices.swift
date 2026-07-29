//
//  BaselinePrices.swift
//  KB_Tune
//
//  공개 통계에서 온 기준 금액.
//
//  일정 이력이 하나도 없는 사람에게 보여줄 금액이다. 앱에 박아 둔 임의의 숫자가 아니라
//  한국소비자원 참가격·국가데이터처 가계동향조사·서울열린데이터광장 상권분석에서 왔고,
//  행마다 출처와 기준 시점이 붙어 있어 화면에 그대로 인용한다.
//
//  표는 통째로 받아 기기에 두고 조회도 기기 안에서 한다. 제목을 서버에 물어보는
//  방식이면 일정 제목이 밖으로 나가는데, 그건 이 앱이 하지 않기로 한 일이다.
//

import Foundation

enum BaselinePrices {

    struct Table: Codable {
        let version: String
        let events: [Event]
        let items: [Item]
        let monthly: Monthly
    }

    struct Event: Codable {
        let category: String
        let amount: Int
        let low: Int
        let high: Int
        let basis: String
        let source: String
        /// 연령대("20"·"30"·"40"·"50") → 그 나이대의 평균 대비 결제 배수.
        let ageFactors: [String: Double]?

        private enum CodingKeys: String, CodingKey {
            case category, amount, low, high, basis, source
            case ageFactors = "age_factors"
        }
    }

    struct Item: Codable {
        let name: String
        /// 제목에서 찾을 말. 표시 이름과 다르다 — '삼겹살200g'은 제목에 그대로 안 나온다.
        let keywords: [String]?
        let amount: Int
        let low: Int
        let high: Int
        let source: String
    }

    struct Monthly: Codable {
        let scope: String
        let asof: String
        let source: String
        let total: Int
        let bimok: [Bimok]

        struct Bimok: Codable {
            let bimok: String
            let amount: Int
        }
    }

    /// 조회 한 건의 결과. basis·source 는 사용자에게 그대로 보여준다.
    struct Match {
        let amount: Int
        let low: Int
        let high: Int
        let basis: String
        let source: String
    }

    // MARK: - 표 읽기

    /// 내려받아 둔 사본이 있으면 그걸, 없으면 앱에 넣어 둔 사본을 쓴다.
    /// 서버가 죽어도 오프라인이어도 값이 나오도록 앱 사본은 항상 함께 배포한다.
    private(set) static var table: Table = loadBundled()

    private static var cacheURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("baseline_prices.json")
    }

    private static func loadBundled() -> Table {
        if let url = cacheURL, let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode(Table.self, from: data) {
            return cached
        }
        guard let url = Bundle.main.url(forResource: "baseline_prices", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let bundled = try? JSONDecoder().decode(Table.self, from: data) else {
            // 번들 리소스가 빠진 빌드. 표가 없으면 추정은 기존 규칙으로만 돌아간다.
            assertionFailure("baseline_prices.json 이 번들에 없습니다.")
            return Table(version: "none", events: [], items: [],
                         monthly: Monthly(scope: "", asof: "", source: "", total: 0, bimok: []))
        }
        return bundled
    }

    /// 서버에서 최신 표를 받아 캐시한다. 실패하면 조용히 지금 표를 계속 쓴다.
    ///
    /// 이 요청에는 본문이 없다 — 공개 통계를 받아오기만 하므로 나가는 개인 정보가 없다.
    @MainActor static func refresh() async {
        guard let table = await AgentService.fetchBaseline() else { return }
        self.table = table
        if let url = cacheURL, let data = try? JSONEncoder().encode(table) {
            try? data.write(to: url, options: Data.WritingOptions.atomic)
        }
    }

    // MARK: - 조회

    /// 제목에 품목 이름이 그대로 들어 있으면 그 단가. 카테고리 평균보다 구체적이다.
    static func forTitle(_ title: String) -> Match? {
        let compact = title.replacingOccurrences(of: " ", with: "")
        let item = table.items.first { row in
            (row.keywords ?? [row.name])
                .contains { compact.contains($0.replacingOccurrences(of: " ", with: "")) }
        }
        guard let item else { return nil }
        return Match(amount: item.amount, low: item.low, high: item.high,
                     basis: "\(item.name) 평균 \(formatWon(item.amount))",
                     source: item.source)
    }

    /// 카테고리 기준 금액. 대응하는 공개 통계가 없는 카테고리(경조사·업무·학업 등)는 nil.
    static func forCategory(_ category: String, ageBucket: String? = nil) -> Match? {
        guard let event = table.events.first(where: { $0.category == category }) else { return nil }

        let factor = ageBucket.flatMap { event.ageFactors?[$0] }
        guard let factor, let ageBucket else {
            return Match(amount: event.amount, low: event.low, high: event.high,
                         basis: event.basis, source: event.source)
        }
        let scale = { (v: Int) in Int((Double(v) * factor).rounded()) }
        return Match(amount: scale(event.amount), low: scale(event.low), high: scale(event.high),
                     basis: "\(event.basis) · \(ageBucket)대는 평균의 "
                          + String(format: "%.2f", factor) + "배를 써요",
                     source: event.source)
    }

    /// 일정이 하나도 없을 때 쓸 월 지출 뼈대(1인가구 비목별 월평균).
    static var monthly: Monthly { table.monthly }
}
