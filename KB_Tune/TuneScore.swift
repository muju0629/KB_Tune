//
//  TuneScore.swift
//  KB_Tune
//
//  Tune 점수 v0. 목표 달성 가능성·단기 잔액 안전·보호 소비 보존을 한 숫자로 묶되,
//  점수와 신뢰도를 분리하고 모든 항목이 원본 근거를 가리키게 한다.
//

import Foundation

enum TuneConfidence: String, Codable, CaseIterable {
    case low, medium, high

    var label: String {
        switch self {
        case .low: "낮은 신뢰도"
        case .medium: "보통 신뢰도"
        case .high: "높은 신뢰도"
        }
    }

    /// 데이터가 적으면 같은 잔액이어도 더 큰 안전 버퍼를 요구한다.
    var bufferMultiplier: Double {
        switch self {
        case .low: 1.5
        case .medium: 1.25
        case .high: 1.0
        }
    }
}

enum TuneEvidenceSource: String, Codable {
    case transaction, calendar, billing, goal, policy, userChoice, forecast
}

struct TuneEvidenceReference: Codable, Equatable, Identifiable {
    let id: String
    let source: TuneEvidenceSource
    let label: String
    let amount: Int?
    let day: Int?
}

struct TuneScoreInput: Equatable {
    /// 적금 목표를 지킬 확률. 0...1 범위이며 엔진이 경계 밖 값을 잘라낸다.
    let goalProbability: Double
    /// 현재 위험 구간이 끝날 때 예상되는 가용 잔액.
    let projectedBalance: Int
    /// 사용자가 정한 값이 없을 때 적용하는 정책 버퍼.
    let baseSafetyBuffer: Int
    /// 보호 소비를 건드리지 않고 옮기거나 줄일 수 있는 금액.
    let flexibleSpend: Int
    /// 사용자가 지켜두기로 한 소비 금액.
    let protectedSpend: Int
    let observationWeeks: Int
    /// 예정 지출 가운데 캘린더 또는 결제 내역으로 근거가 잡힌 비율. 0...1.
    let calendarCoverage: Double
    let evidence: [TuneEvidenceReference]
}

struct TuneScoreComponent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case goalViability, liquiditySafety, valuePreservation

        var label: String {
            switch self {
            case .goalViability: "목표 지속력"
            case .liquiditySafety: "잔액 안전도"
            case .valuePreservation: "보호 소비 보존도"
            }
        }
    }

    let kind: Kind
    let score: Int
    let weight: Double
    let explanation: String
    let evidenceIDs: [String]
    var id: String { kind.rawValue }
}

struct TuneScoreResult: Codable, Equatable {
    let score: Int
    let confidence: TuneConfidence
    let effectiveSafetyBuffer: Int
    let requiredAdjustment: Int
    let components: [TuneScoreComponent]
    let evidence: [TuneEvidenceReference]

    func component(_ kind: TuneScoreComponent.Kind) -> TuneScoreComponent? {
        components.first { $0.kind == kind }
    }
}

enum TuneScoreEngine {
    // v0 정책 가중치. 실사용 백테스트 전에는 검증된 인과 가중치라고 주장하지 않는다.
    static let goalWeight = 0.55
    static let liquidityWeight = 0.30
    static let preservationWeight = 0.15

    static func calculate(_ input: TuneScoreInput) -> TuneScoreResult {
        let confidence = confidence(for: input)
        let baseBuffer = max(1, input.baseSafetyBuffer)
        let effectiveBuffer = Int((Double(baseBuffer) * confidence.bufferMultiplier).rounded())
        let projected = input.projectedBalance
        let flexible = max(0, input.flexibleSpend)
        let protected = max(0, input.protectedSpend)

        let goal = roundedScore(clamp(input.goalProbability) * 100)
        let liquidity = roundedScore(clamp(Double(projected) / Double(effectiveBuffer)) * 100)

        let required = max(0, effectiveBuffer - projected)
        let protectedShortfall = max(0, required - flexible)
        let preservation: Int
        if protected == 0 || protectedShortfall == 0 {
            preservation = 100
        } else {
            preservation = roundedScore(
                clamp(1 - Double(protectedShortfall) / Double(protected)) * 100
            )
        }

        let goalEvidence = input.evidence.filter { [.goal, .forecast].contains($0.source) }.map(\.id)
        let liquidityEvidence = input.evidence.filter {
            [.transaction, .calendar, .billing, .policy, .forecast].contains($0.source)
        }.map(\.id)
        let preservationEvidence = input.evidence.filter {
            [.calendar, .userChoice, .policy].contains($0.source)
        }.map(\.id)

        let components = [
            TuneScoreComponent(
                kind: .goalViability, score: goal, weight: goalWeight,
                explanation: "현재 계획에서 적금 목표를 지킬 확률 \(goal)%를 반영했어요.",
                evidenceIDs: goalEvidence
            ),
            TuneScoreComponent(
                kind: .liquiditySafety, score: liquidity, weight: liquidityWeight,
                explanation: "예상 잔액 \(won(projected))을 안전 버퍼 \(won(effectiveBuffer))와 비교했어요.",
                evidenceIDs: liquidityEvidence
            ),
            TuneScoreComponent(
                kind: .valuePreservation, score: preservation, weight: preservationWeight,
                explanation: protected == 0
                    ? "현재 위험 구간에는 보호 소비가 없어요."
                    : (protectedShortfall == 0
                        ? "보호 소비를 건드리지 않고 필요한 조정을 만들 수 있어요."
                        : "보호 소비를 지키려면 \(won(protectedShortfall))의 여유가 더 필요해요."),
                evidenceIDs: preservationEvidence
            ),
        ]

        let total = Int((Double(goal) * goalWeight
                         + Double(liquidity) * liquidityWeight
                         + Double(preservation) * preservationWeight).rounded())
        return TuneScoreResult(
            score: max(0, min(100, total)),
            confidence: confidence,
            effectiveSafetyBuffer: effectiveBuffer,
            requiredAdjustment: required,
            components: components,
            evidence: input.evidence
        )
    }

    private static func confidence(for input: TuneScoreInput) -> TuneConfidence {
        let coverage = clamp(input.calendarCoverage)
        if input.observationWeeks >= 8, coverage >= 0.8 { return .high }
        if input.observationWeeks >= 4, coverage >= 0.5 { return .medium }
        return .low
    }

    private static func clamp(_ value: Double) -> Double { max(0, min(1, value)) }
    private static func roundedScore(_ value: Double) -> Int {
        max(0, min(100, Int(value.rounded())))
    }
    private static func won(_ amount: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? String(amount))원"
    }
}
