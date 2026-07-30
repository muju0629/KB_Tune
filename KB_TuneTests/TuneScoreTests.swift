import Foundation
import Testing
@testable import KB_Tune

@MainActor
@Suite(.serialized)
struct TuneScoreTests {
    private let evidence = [
        TuneEvidenceReference(id: "goal", source: .goal,
                              label: "적금 목표", amount: 800_000, day: nil),
        TuneEvidenceReference(id: "calendar-1", source: .calendar,
                              label: "저녁 일정", amount: 40_000, day: 22),
        TuneEvidenceReference(id: "buffer", source: .policy,
                              label: "안전 버퍼", amount: 100_000, day: nil),
    ]

    private func input(
        probability: Double = 0.8,
        balance: Int = 100_000,
        buffer: Int = 100_000,
        flexible: Int = 100_000,
        protected: Int = 50_000,
        weeks: Int = 8,
        coverage: Double = 1
    ) -> TuneScoreInput {
        TuneScoreInput(
            goalProbability: probability, projectedBalance: balance,
            baseSafetyBuffer: buffer, flexibleSpend: flexible,
            protectedSpend: protected, observationWeeks: weeks,
            calendarCoverage: coverage, evidence: evidence
        )
    }

    @Test func scoreClampsBoundaryValuesAndTracksEvidence() throws {
        let high = TuneScoreEngine.calculate(input(probability: 2, balance: 200_000))
        #expect(high.score == 100)
        #expect(high.component(.goalViability)?.score == 100)
        #expect(high.component(.goalViability)?.evidenceIDs.contains("goal") == true)
        #expect(high.component(.liquiditySafety)?.evidenceIDs.contains("buffer") == true)

        let low = TuneScoreEngine.calculate(input(
            probability: -1, balance: -100_000, flexible: 0, protected: 100_000
        ))
        #expect(low.score == 0)
        #expect(low.components.allSatisfy { (0...100).contains($0.score) })
        #expect(low.evidence == evidence)
    }

    @Test func noProtectedSpendDoesNotCreateAFakeProtectionPenalty() {
        let result = TuneScoreEngine.calculate(input(
            probability: 0, balance: -100_000, flexible: 0, protected: 0
        ))

        #expect(result.component(.valuePreservation)?.score == 100)
        #expect(result.score == 15)
    }

    @Test func lowConfidenceUsesAConservativeBufferWithoutChangingTheLabelToCertainty() {
        let low = TuneScoreEngine.calculate(input(balance: 100_000, weeks: 2, coverage: 0.3))
        let high = TuneScoreEngine.calculate(input(balance: 100_000, weeks: 8, coverage: 1))

        #expect(low.confidence == .low)
        #expect(low.effectiveSafetyBuffer == 150_000)
        #expect(high.confidence == .high)
        #expect(high.effectiveSafetyBuffer == 100_000)
        #expect(low.component(.liquiditySafety)!.score < high.component(.liquiditySafety)!.score)
    }

    @Test func protectedAndConfirmedSpendAreNeverExecutableCandidates() throws {
        let protectedID = UUID()
        let confirmedID = UUID()
        let adjustableID = UUID()
        let candidates = TuneAdjustmentEngine.candidates(
            expenses: [
                TuneExpenseSnapshot(id: protectedID, day: 22, title: "친구 결혼식",
                                    amount: 70_000, state: .reserved, isProtected: true),
                TuneExpenseSnapshot(id: confirmedID, day: 23, title: "자동이체",
                                    amount: 100_000, state: .confirmed, isProtected: false),
                TuneExpenseSnapshot(id: adjustableID, day: 24, title: "팀 외식",
                                    amount: 60_000, state: .reserved, isProtected: false),
            ],
            planEndDay: 31,
            savingsGoal: 800_000,
            scoreInput: input(balance: 0)
        )

        let protected = try #require(candidates.first { $0.eventID == protectedID })
        let confirmed = try #require(candidates.first { $0.eventID == confirmedID })
        let savings = try #require(candidates.first { $0.kind == .keepSavings })
        let adjustable = try #require(candidates.first { $0.eventID == adjustableID })

        #expect(protected.status == .excluded)
        #expect(protected.reason == .protectedByUser)
        #expect(confirmed.status == .excluded)
        #expect(confirmed.reason == .confirmedPayment)
        #expect(savings.status == .excluded)
        #expect(savings.reason == .savingsGoalProtected)
        #expect(adjustable.status == .recommended)
        #expect(candidates.filter { $0.isExecutable && $0.eventID == protectedID }.isEmpty)
    }

    @Test func rejectedCandidateIsNotRecommendedAgain() throws {
        let id = UUID()
        let snapshot = TuneExpenseSnapshot(id: id, day: 22, title: "팀 외식",
                                           amount: 60_000, state: .reserved, isProtected: false)
        let first = TuneAdjustmentEngine.candidates(
            expenses: [snapshot], planEndDay: 31, savingsGoal: 800_000,
            scoreInput: input(balance: 0)
        )
        let candidate = try #require(first.first { $0.eventID == id })
        let second = TuneAdjustmentEngine.candidates(
            expenses: [snapshot], planEndDay: 31, savingsGoal: 800_000,
            scoreInput: input(balance: 0), rejectedIDs: [candidate.id]
        )
        let rejected = try #require(second.first { $0.eventID == id })

        #expect(rejected.status == .excluded)
        #expect(rejected.reason == .userRejected)
        #expect(!rejected.isExecutable)
    }

    @Test func riskDetectionHasThresholdCooldownAndNoAutomaticAction() throws {
        let score = TuneScoreEngine.calculate(input(probability: 0.4, balance: 0))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try #require(TuneRiskDetector.detect(
            current: score, previousScore: score.score + 11,
            goalProbability: 0.4, upcomingCalendarCount: 2,
            upcomingBilling: 300_000, now: now
        ))
        #expect(first.requiresApproval)
        #expect(first.reasons.contains(.scoreDrop))
        #expect(first.reasons.contains(.scheduleBillingOverlap))

        let history = [TuneAlertHistory(fingerprint: first.id, notifiedAt: now)]
        #expect(TuneRiskDetector.detect(
            current: score, previousScore: score.score + 11,
            goalProbability: 0.4, upcomingCalendarCount: 2,
            upcomingBilling: 300_000, now: now.addingTimeInterval(60), history: history
        ) == nil)
        #expect(TuneRiskDetector.detect(
            current: score, previousScore: score.score + 11,
            goalProbability: 0.4, upcomingCalendarCount: 2,
            upcomingBilling: 300_000,
            now: now.addingTimeInterval(TuneRiskDetector.cooldown + 1), history: history
        ) != nil)
    }

    @Test func calculatingCandidatesDoesNotMutateThePlanWithoutApproval() {
        DemoClock.fixedToday = 22
        defer { DemoClock.fixedToday = nil }
        let model = AppModel()
        let before = model.calendarDays.flatMap { day in
            day.events.map { (day.dayNumber, $0.id, $0.amount) }
        }

        _ = model.tuneAdjustmentCandidates

        let after = model.calendarDays.flatMap { day in
            day.events.map { (day.dayNumber, $0.id, $0.amount) }
        }
        #expect(before.count == after.count)
        #expect(zip(before, after).allSatisfy {
            $0.0.0 == $0.1.0 && $0.0.1 == $0.1.1 && $0.0.2 == $0.1.2
        })
    }

    @Test func onboardingPurposeAlsoActsAsAProtectionConstraint() {
        let model = AppModel()
        model.hobbies = ["모임"]
        let event = DayEvent(title: "친구 저녁", symbol: "person.2", startHour: 19,
                             duration: 2, amount: 40_000,
                             category: "외식", purpose: "모임", state: .reserved)

        #expect(model.isProtectedSpend(event))
    }

    @Test func auditLogAndRejectedIDsSurviveStateRoundTrip() throws {
        let candidateID = "move-test"
        let entry = TuneAuditEntry(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            event: .adjustmentApproved, fingerprint: nil,
            candidateID: candidateID, label: "팀 외식",
            scoreBefore: 61, scoreAfter: 74,
            reasonCodes: [TuneAdjustmentReason.bestRecovery.rawValue],
            evidenceIDs: ["calendar-1"],
            modelVersion: "forecast-test-v1",
            featureVersion: "feature-test-v1"
        )
        let state = PersistedState(
            hasOnboarded: true, usesDemoData: true, kbPayLinked: false,
            monthlyIncome: 2_200_000, savingsGoal: 800_000,
            direction: .maintain, hobbies: [], calendarDays: AppModel.makeCalendar(),
            dismissedPredictions: [],
            tuneAuditLog: [entry], rejectedAdjustmentIDs: [candidateID]
        )

        let restored = try JSONDecoder().decode(
            PersistedState.self, from: JSONEncoder().encode(state)
        )
        #expect(restored.tuneAuditLog == [entry])
        #expect(restored.tuneAuditLog.first?.modelVersion == "forecast-test-v1")
        #expect(restored.tuneAuditLog.first?.featureVersion == "feature-test-v1")
        #expect(restored.rejectedAdjustmentIDs == [candidateID])
    }
}
