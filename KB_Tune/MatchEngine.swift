//
//  MatchEngine.swift
//  KB_Tune
//
//  일정-거래 매칭 (기획 보고서 8.1).
//
//  카드사 앱은 '네이버페이 63,000원'을 영영 기타로 둘 수밖에 없다. 가맹점이 결제대행이라
//  실제로 뭘 샀는지 모르기 때문이다. KB_Tune은 그날 캘린더에 뭐가 있었는지를 알기에
//  "그 시간에 있던 일정과 연결된 결제 아닌가요?"를 물어볼 수 있다. 그게 이 파일의 존재 이유다.
//
//  보고서는 5개 기준(제목·시간·장소·과거유사·이동패턴)에 가중치를 준다.
//  이 앱의 카드 데이터에는 장소와 이동 정보가 없어서 그 두 축은 계산할 수 없다.
//  없는 기준을 0점으로 깔면 아무 거래도 임계값을 못 넘으므로,
//  **계산 가능한 기준의 만점을 기준으로 환산**하고 어떤 기준을 못 썼는지 화면에 밝힌다.
//

import Foundation

// MARK: - 판정

struct MatchCriterion: Identifiable {
    let id = UUID()
    let name: String
    let earned: Int
    let max: Int
    let note: String
}

struct MatchResult: Identifiable {
    let id = UUID()
    let transaction: CardTransaction
    let event: DayEvent
    let dayNumber: Int
    let criteria: [MatchCriterion]

    var earned: Int { criteria.reduce(0) { $0 + $1.earned } }
    /// 계산할 수 있었던 기준의 만점. 장소·이동 축이 없으므로 100이 아니다.
    var available: Int { criteria.reduce(0) { $0 + $1.max } }
    /// 0~100 환산 점수 — 보고서의 80/50 임계값을 그대로 쓰기 위해.
    var score: Int { available == 0 ? 0 : Int((Double(earned) / Double(available) * 100).rounded()) }

    var verdict: MatchEngine.Verdict {
        if score >= 80 { return .auto }
        if score >= 50 { return .confirm }
        return .unrelated
    }
}

// MARK: - 엔진

enum MatchEngine {

    enum Verdict {
        case auto        // 80점 이상 — 자동 연결
        case confirm     // 50~79점 — 사용자 확인 요청
        case unrelated   // 50점 미만 — 일반 소비로 남김

        var label: String {
            switch self {
            case .auto: "자동 연결"
            case .confirm: "확인 필요"
            case .unrelated: "일반 소비"
            }
        }
    }

    /// 보고서 8.1의 가중치. 장소(20)·이동패턴(10)은 데이터가 없어 빠져 있다.
    static let categoryWeight = 30
    static let timeWeight = 25
    static let amountWeight = 15

    /// 거래 하나에 대해 같은 날 일정 중 가장 잘 맞는 것을 찾는다.
    static func bestMatch(for tx: CardTransaction, in model: AppModel) -> MatchResult? {
        guard let day = model.day(number: tx.day) else { return nil }

        // 금액이 0인 일정도 후보다 — '오디움 예약'처럼 예약만 잡고 금액을 모르는 일정이야말로
        // 카드 내역이 금액을 알려줘야 하는 대상이다. 대신 하루를 통째로 덮는 배경 일정
        // (출근 9시간 등)은 뺀다. 시간이 길어 아무 결제나 시간 점수를 다 먹기 때문이다.
        let candidates = day.events
            .filter { $0.duration < 6 }
            .map { score(tx: tx, event: $0, dayNumber: tx.day) }
            .sorted { $0.earned > $1.earned }

        return candidates.first
    }

    /// 확인이 필요한(50~79점) 거래들 — 하루 마감에서 물어볼 목록.
    static func needsConfirmation(in model: AppModel, day: Int) -> [MatchResult] {
        BillingCycle.transactions
            .filter { $0.day == day && $0.count == 1 }
            .compactMap { bestMatch(for: $0, in: model) }
            .filter { $0.verdict == .confirm }
    }

    // MARK: 기준별 점수

    private static func score(tx: CardTransaction, event: DayEvent, dayNumber: Int) -> MatchResult {
        MatchResult(transaction: tx, event: event, dayNumber: dayNumber,
                    criteria: [categoryScore(tx, event), timeScore(tx, event), amountScore(tx, event)])
    }

    /// 결제 업종과 일정 카테고리가 같은 생활 목적인가.
    private static func categoryScore(_ tx: CardTransaction, _ event: DayEvent) -> MatchCriterion {
        let (txCategory, _) = LocalExtractor.category(for: tx.merchant)
        let eventCategory = event.category

        // 양쪽 다 '기타'인 건 일치가 아니라 둘 다 모르는 것 — 만점을 주면 안 된다.
        if txCategory == "기타" && eventCategory == "기타" {
            return MatchCriterion(name: "업종 일치", earned: categoryWeight * 3 / 10, max: categoryWeight,
                                  note: "양쪽 다 업종을 알 수 없어요")
        }
        if txCategory == eventCategory {
            return MatchCriterion(name: "업종 일치", earned: categoryWeight, max: categoryWeight,
                                  note: "둘 다 \(txCategory)예요")
        }
        if related(txCategory, eventCategory) {
            return MatchCriterion(name: "업종 일치", earned: categoryWeight * 6 / 10, max: categoryWeight,
                                  note: "\(txCategory)와 \(eventCategory)는 같이 쓰는 소비예요")
        }
        if txCategory == "기타" {
            // 결제대행이라 업종을 모르는 경우 — 틀렸다고 깎지 않고 판단을 보류한다.
            return MatchCriterion(name: "업종 일치", earned: categoryWeight * 3 / 10, max: categoryWeight,
                                  note: "결제대행이라 업종을 알 수 없어요")
        }
        return MatchCriterion(name: "업종 일치", earned: 0, max: categoryWeight,
                              note: "\(txCategory) 결제인데 일정은 \(eventCategory)예요")
    }

    /// 결제 시각이 일정 시간대에 얼마나 가까운가.
    private static func timeScore(_ tx: CardTransaction, _ event: DayEvent) -> MatchCriterion {
        guard let hour = tx.hour else {
            return MatchCriterion(name: "시간 근접성", earned: 0, max: 0, note: "결제 시각을 모르는 건이에요")
        }
        let start = event.startHour
        let end = event.startHour + event.duration

        if hour >= start && hour <= end {
            return MatchCriterion(name: "시간 근접성", earned: timeWeight, max: timeWeight,
                                  note: "일정 진행 중에 결제했어요")
        }
        let gap = hour < start ? start - hour : hour - end
        let minutes = Int(gap * 60)
        switch gap {
        case ..<0.5:
            return MatchCriterion(name: "시간 근접성", earned: timeWeight * 8 / 10, max: timeWeight,
                                  note: "일정과 \(minutes)분 차이예요")
        case ..<1.0:
            return MatchCriterion(name: "시간 근접성", earned: timeWeight * 55 / 100, max: timeWeight,
                                  note: "일정과 \(minutes)분 차이예요")
        case ..<2.0:
            return MatchCriterion(name: "시간 근접성", earned: timeWeight * 25 / 100, max: timeWeight,
                                  note: "일정과 \(minutes)분 차이예요")
        default:
            return MatchCriterion(name: "시간 근접성", earned: 0, max: timeWeight,
                                  note: "일정과 \(Int(gap))시간 넘게 떨어져 있어요")
        }
    }

    /// 예상 금액과 실제 결제액이 비슷한가 (보고서의 '과거 유사 일정과 금액 유사성').
    private static func amountScore(_ tx: CardTransaction, _ event: DayEvent) -> MatchCriterion {
        guard event.amount > 0 else {
            return MatchCriterion(name: "금액 유사성", earned: 0, max: 0, note: "일정에 예상 금액이 없어요")
        }
        let diff = abs(Double(tx.amount - event.amount)) / Double(event.amount)
        switch diff {
        case ..<0.3:
            return MatchCriterion(name: "금액 유사성", earned: amountWeight, max: amountWeight,
                                  note: "예상 \(formatWon(event.amount))과 비슷해요")
        case ..<0.6:
            return MatchCriterion(name: "금액 유사성", earned: amountWeight * 5 / 10, max: amountWeight,
                                  note: "예상 \(formatWon(event.amount))과 차이가 있어요")
        default:
            return MatchCriterion(name: "금액 유사성", earned: 0, max: amountWeight,
                                  note: "예상 \(formatWon(event.amount))과 많이 달라요")
        }
    }

    /// 같이 붙어 다니는 소비 — 저녁 자리에 배달·카페가 섞이는 식.
    private static func related(_ a: String, _ b: String) -> Bool {
        let groups: [Set<String>] = [
            ["외식", "배달", "카페", "술·모임", "모임", "데이트", "가족"],
            ["쇼핑", "자기관리", "건강", "생활", "경조사"],
            ["교통", "여가", "문화", "출근", "업무·학업"],
        ]
        return groups.contains { $0.contains(a) && $0.contains(b) }
    }
}
