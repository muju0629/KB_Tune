//
//  AdjustmentEngine.swift
//  KB_Tune
//
//  보호 제약을 먼저 적용한 뒤 실행 가능한 조정안만 점수 변화와 함께 비교한다.
//  제외 후보도 버리지 않는다. 사용자가 "왜 추천하지 않았는지" 확인하는 감사 자료다.
//

import Foundation

enum TuneAdjustmentKind: String, Codable {
    case moveNextWeek, reduceAmount, keepProtected, keepSavings
}

enum TuneCandidateStatus: String, Codable {
    case recommended, alternative, excluded

    var label: String {
        switch self {
        case .recommended: "추천"
        case .alternative: "보조안"
        case .excluded: "제외"
        }
    }
}

enum TuneAdjustmentReason: String, Codable {
    case bestRecovery
    case partialRecovery
    case protectedByUser
    case confirmedPayment
    case savingsGoalProtected
    case userRejected
    case noSafeAdjustment

    var message: String {
        switch self {
        case .bestRecovery: "보호 소비를 유지하면서 Tune 점수를 가장 많이 회복해요."
        case .partialRecovery: "보호 소비를 유지하는 대안이에요."
        case .protectedByUser: "사용자가 지켜두기로 한 소비라 변경하지 않아요."
        case .confirmedPayment: "이미 결제했거나 반드시 납부할 지출이라 변경하지 않아요."
        case .savingsGoalProtected: "장기 목표를 훼손하므로 적금 자동이체 취소는 제안하지 않아요."
        case .userRejected: "사용자가 앞서 거절한 조정안이라 다시 추천하지 않아요."
        case .noSafeAdjustment: "금액이 작거나 옮길 날짜가 없어 안전한 조정안을 만들지 못했어요."
        }
    }
}

struct TuneExpenseSnapshot: Equatable {
    let id: UUID
    let day: Int
    let title: String
    let amount: Int
    let state: SpendState
    let isProtected: Bool
}

struct TuneAdjustmentCandidate: Identifiable, Equatable {
    let id: String
    let kind: TuneAdjustmentKind
    let eventID: UUID?
    let day: Int?
    let targetDay: Int?
    let title: String
    let amountBefore: Int
    let amountAfter: Int
    let gain: Int
    var status: TuneCandidateStatus
    var reason: TuneAdjustmentReason
    let scoreBefore: Int
    let scoreAfter: Int?

    var isExecutable: Bool { status != .excluded && eventID != nil }
}

enum TuneAdjustmentEngine {
    static func candidates(
        expenses: [TuneExpenseSnapshot],
        planEndDay: Int,
        savingsGoal: Int,
        scoreInput: TuneScoreInput,
        rejectedIDs: Set<String> = []
    ) -> [TuneAdjustmentCandidate] {
        let before = TuneScoreEngine.calculate(scoreInput)
        var result: [TuneAdjustmentCandidate] = []

        for expense in expenses where expense.amount > 0 {
            let movable = expense.day + 7 <= planEndDay
            let kind: TuneAdjustmentKind = movable ? .moveNextWeek : .reduceAmount
            let candidateID = "\(kind.rawValue)-\(expense.id.uuidString)"

            if rejectedIDs.contains(candidateID) {
                result.append(excluded(expense, id: candidateID, kind: kind,
                                       reason: .userRejected, score: before.score))
                continue
            }
            if expense.isProtected {
                result.append(excluded(expense, id: candidateID, kind: .keepProtected,
                                       reason: .protectedByUser, score: before.score))
                continue
            }
            if expense.state == .confirmed {
                result.append(excluded(expense, id: candidateID, kind: kind,
                                       reason: .confirmedPayment, score: before.score))
                continue
            }

            let reduced = (expense.amount / 2 / 10_000) * 10_000
            let afterAmount = movable ? expense.amount : reduced
            let gain = movable ? expense.amount : expense.amount - reduced
            guard gain > 0, movable || reduced > 0 else {
                result.append(excluded(expense, id: candidateID, kind: kind,
                                       reason: .noSafeAdjustment, score: before.score))
                continue
            }

            let afterInput = TuneScoreInput(
                goalProbability: scoreInput.goalProbability,
                projectedBalance: scoreInput.projectedBalance + gain,
                baseSafetyBuffer: scoreInput.baseSafetyBuffer,
                flexibleSpend: max(0, scoreInput.flexibleSpend - gain),
                protectedSpend: scoreInput.protectedSpend,
                observationWeeks: scoreInput.observationWeeks,
                calendarCoverage: scoreInput.calendarCoverage,
                evidence: scoreInput.evidence
            )
            let after = TuneScoreEngine.calculate(afterInput)
            result.append(TuneAdjustmentCandidate(
                id: candidateID, kind: kind, eventID: expense.id, day: expense.day,
                targetDay: movable ? expense.day + 7 : nil,
                title: expense.title, amountBefore: expense.amount, amountAfter: afterAmount,
                gain: gain, status: .alternative, reason: .partialRecovery,
                scoreBefore: before.score, scoreAfter: after.score
            ))
        }

        result.append(TuneAdjustmentCandidate(
            id: "keep-savings-goal", kind: .keepSavings, eventID: nil, day: nil,
            targetDay: nil, title: "적금 자동이체 취소", amountBefore: savingsGoal,
            amountAfter: savingsGoal, gain: 0, status: .excluded,
            reason: .savingsGoalProtected, scoreBefore: before.score, scoreAfter: nil
        ))

        let bestID = result
            .filter(\.isExecutable)
            .max {
                let left = ($0.scoreAfter ?? $0.scoreBefore) - $0.scoreBefore
                let right = ($1.scoreAfter ?? $1.scoreBefore) - $1.scoreBefore
                return (left, $0.gain) < (right, $1.gain)
            }?.id

        for index in result.indices where result[index].id == bestID {
            result[index].status = .recommended
            result[index].reason = .bestRecovery
        }

        return result.sorted {
            let order: [TuneCandidateStatus: Int] = [.recommended: 0, .alternative: 1, .excluded: 2]
            if order[$0.status] != order[$1.status] {
                return (order[$0.status] ?? 3) < (order[$1.status] ?? 3)
            }
            return $0.gain > $1.gain
        }
    }

    private static func excluded(
        _ expense: TuneExpenseSnapshot,
        id: String,
        kind: TuneAdjustmentKind,
        reason: TuneAdjustmentReason,
        score: Int
    ) -> TuneAdjustmentCandidate {
        TuneAdjustmentCandidate(
            id: id, kind: kind, eventID: expense.id, day: expense.day, targetDay: nil,
            title: expense.title, amountBefore: expense.amount, amountAfter: expense.amount,
            gain: 0, status: .excluded, reason: reason,
            scoreBefore: score, scoreAfter: nil
        )
    }
}
