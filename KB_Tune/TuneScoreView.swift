//
//  TuneScoreView.swift
//  KB_Tune
//
//  Tune 점수의 세 항목, 계산 근거, 추천·제외 후보와 감사 로그를 한 화면에서 보여준다.
//

import SwiftUI

struct TuneScoreSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onApprove: (TuneAdjustmentCandidate) -> Bool
    var onMessage: (String) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    scoreHeader
                    candidateSection
                    evidenceSection
                    auditSection
                }
                .padding(20)
            }
            .background(KB.canvas)
            .navigationTitle("Tune 점수")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }

    private var scoreHeader: some View {
        let result = model.tuneScore
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(result.score)점")
                    .money(42, weight: .heavy).foregroundStyle(KB.ink)
                    .accessibilityIdentifier("tune-score-value")
                Spacer()
                LabelBadge(text: confidenceLabel(result.confidence),
                           color: result.confidence == .low ? KB.caution : KB.green)
            }
            Text("약속과 저축 목표를 함께 지킬 수 있는 정도예요.")
                .font(.kb(14, .medium)).foregroundStyle(KB.ink)
            if let forecast = model.weeklyForecast {
                Text("예측 \(forecast.modelVersion) · 피처 \(forecast.featureVersion)")
                    .font(.kb(10.5)).foregroundStyle(KB.muted)
                    .accessibilityIdentifier("tune-model-version")
            }
        }
        .padding(18)
        .background(KB.yellowSoft, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func confidenceLabel(_ confidence: TuneConfidence) -> String {
        switch confidence {
        case .low: "데이터 신뢰도 낮음"
        case .medium: "데이터 신뢰도 보통"
        case .high: "데이터 신뢰도 높음"
        }
    }

    private var candidateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("조정안 비교")
                .font(.kb(17, .bold)).foregroundStyle(KB.ink)
                .accessibilityIdentifier("tune-adjustment-comparison")
            ForEach(model.tuneAdjustmentCandidates) { candidate in
                candidateRow(candidate)
            }
        }
    }

    private func candidateRow(_ candidate: TuneAdjustmentCandidate) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                LabelBadge(text: candidate.status.label,
                           color: candidate.status == .excluded ? KB.muted : KB.violet)
                Text(candidateTitle(candidate)).font(.kb(14, .bold)).foregroundStyle(KB.ink)
                Spacer()
                if let after = candidate.scoreAfter {
                    Text("\(candidate.scoreBefore) → \(after)점")
                        .money(12.5).foregroundStyle(after > candidate.scoreBefore ? KB.green : KB.muted)
                }
            }
            Text(candidate.reason.message)
                .font(.kb(12.5)).foregroundStyle(KB.muted).fixedSize(horizontal: false, vertical: true)

            if candidate.isExecutable {
                Button {
                    if onApprove(candidate) {
                        onMessage("‘\(candidate.title)’ 조정안을 승인하고 계획을 다시 계산했어요.")
                    }
                } label: {
                    HStack {
                        Text("이 안 적용하기")
                        Spacer()
                        Text("+\(formatWon(candidate.gain))").lineLimit(1)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("apply-adjustment")

                Button("이 안은 제외") {
                    model.rejectAdjustment(candidate)
                    onMessage("이 조정안은 다시 추천하지 않을게요.")
                }
                .font(.kb(12.5, .medium))
                .foregroundStyle(KB.muted)
                .frame(maxWidth: .infinity)
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(candidate.status == .excluded ? KB.surface : KB.greenSoft,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(candidate.status == .excluded ? KB.line : KB.green.opacity(0.25), lineWidth: 1))
    }

    private func candidateTitle(_ candidate: TuneAdjustmentCandidate) -> String {
        switch candidate.kind {
        case .moveNextWeek: "\(candidate.title) · 다음 주로 이동"
        case .reduceAmount: "\(candidate.title) · 금액 줄이기"
        case .keepProtected, .keepSavings: candidate.title
        }
    }

    private var evidenceSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.tuneScore.evidence) { evidence in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(evidence.label).font(.kb(12.5, .medium)).foregroundStyle(KB.ink)
                        }
                        Spacer()
                        if let amount = evidence.amount {
                            Text(formatWon(amount)).money(11.5).foregroundStyle(KB.ink)
                        }
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            Text("계산 근거 \(model.tuneScore.evidence.count)건 보기")
                .font(.kb(14, .semibold)).foregroundStyle(KB.ink)
        }
        .padding(16)
        .background(KB.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    @ViewBuilder
    private var auditSection: some View {
        if !model.tuneAuditLog.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.tuneAuditLog.suffix(3).reversed()) { entry in
                        HStack(alignment: .top) {
                            Image(systemName: entry.event == .adjustmentApproved
                                  ? "checkmark.circle.fill" : "doc.text.magnifyingglass")
                                .foregroundStyle(KB.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.label).font(.kb(12.5, .semibold)).foregroundStyle(KB.ink)
                                Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                                    .font(.kb(10.5)).foregroundStyle(KB.muted)
                            }
                            Spacer()
                            if let after = entry.scoreAfter {
                                Text("\(entry.scoreBefore) → \(after)점")
                                    .money(11.5).foregroundStyle(KB.ink)
                            }
                        }
                        if let version = entry.modelVersion {
                            Text("모델 \(version)")
                                .font(.kb(9.5)).foregroundStyle(KB.muted)
                                .padding(.leading, 28)
                        }
                    }
                }
                .padding(.top, 10)
            } label: {
                Text("최근 판단 기록")
                    .font(.kb(14, .semibold)).foregroundStyle(KB.ink)
            }
            .padding(16)
            .background(KB.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
        }
    }
}
