//
//  RiskDetector.swift
//  KB_Tune
//
//  선제 경보 정책. 위험을 감지해 설명할 뿐, 조정안을 자동 실행하지 않는다.
//

import Foundation

enum TuneRiskReason: String, Codable, CaseIterable {
    case scoreDrop, lowScore, liquidityShortage, goalAtRisk, scheduleBillingOverlap

    var message: String {
        switch self {
        case .scoreDrop: "Tune 점수가 이전 판단보다 10점 이상 낮아졌어요."
        case .lowScore: "현재 Tune 점수가 주의 기준 아래예요."
        case .liquidityShortage: "안전 버퍼보다 예상 잔액이 부족해요."
        case .goalAtRisk: "적금 목표 달성 가능성이 60% 아래예요."
        case .scheduleBillingOverlap: "예정된 지출과 카드 결제일이 같은 위험 구간에 겹쳐요."
        }
    }
}

struct TuneRiskAlert: Identifiable, Equatable {
    let id: String
    let score: Int
    let reasons: [TuneRiskReason]
    let createdAt: Date
    let requiresApproval: Bool
}

struct TuneAlertHistory: Codable, Equatable {
    let fingerprint: String
    let notifiedAt: Date
}

enum TuneRiskDetector {
    static let cooldown: TimeInterval = 24 * 60 * 60

    static func detect(
        current: TuneScoreResult,
        previousScore: Int?,
        goalProbability: Double,
        upcomingCalendarCount: Int,
        upcomingBilling: Int,
        now: Date = Date(),
        history: [TuneAlertHistory] = []
    ) -> TuneRiskAlert? {
        var reasons: [TuneRiskReason] = []
        if let previousScore, previousScore - current.score >= 10 { reasons.append(.scoreDrop) }
        if current.score <= 65 { reasons.append(.lowScore) }
        if (current.component(.liquiditySafety)?.score ?? 100) <= 40 {
            reasons.append(.liquidityShortage)
        }
        if goalProbability <= 0.60 { reasons.append(.goalAtRisk) }
        if upcomingCalendarCount >= 2, upcomingBilling > 0 {
            reasons.append(.scheduleBillingOverlap)
        }
        guard !reasons.isEmpty else { return nil }

        let fingerprint = reasons.map(\.rawValue).sorted().joined(separator: "+")
        let duplicated = history.contains {
            $0.fingerprint == fingerprint
                && now.timeIntervalSince($0.notifiedAt) >= 0
                && now.timeIntervalSince($0.notifiedAt) < cooldown
        }
        guard !duplicated else { return nil }

        return TuneRiskAlert(
            id: fingerprint, score: current.score, reasons: reasons,
            createdAt: now, requiresApproval: true
        )
    }
}
