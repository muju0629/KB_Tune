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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onApprove: (TuneAdjustmentCandidate) -> Bool
    var onMessage: (String) -> Void

    /// 조정 직후 점수가 얼마나 올랐는지. 사용자가 일으킨 변화라 여기에만 모션을 둔다.
    @State private var gainedPoints = 0
    @State private var pop = false

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
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(result.score)")
                    .money(46, weight: .heavy).foregroundStyle(scoreColor(result.score))
                    .contentTransition(.numericText(value: Double(result.score)))
                    .scaleEffect(pop ? 1.12 : 1, anchor: .bottomLeading)
                    .accessibilityIdentifier("tune-score-value")
                Text("/ 100")
                    .font(.kb(15, .semibold)).foregroundStyle(KB.muted)
                if gainedPoints > 0 {
                    Text("+\(gainedPoints)")
                        .money(17, weight: .bold).foregroundStyle(KB.green)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityLabel("\(gainedPoints)점 올랐어요")
                }
                Spacer(minLength: 8)
                Text(zone(result.score).label)
                    .font(.kb(12, .semibold)).foregroundStyle(scoreColor(result.score))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(scoreColor(result.score).opacity(0.15), in: Capsule())
            }

            scoreScale(result.score)

            Text(zone(result.score).advice)
                .font(.kb(13)).foregroundStyle(KB.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(KB.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(pop ? KB.green.opacity(0.5) : KB.line, lineWidth: 1))
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.6), value: pop)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: gainedPoints)
        .sensoryFeedback(.success, trigger: gainedPoints)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tune 점수 100점 만점에 \(result.score)점, \(zone(result.score).label). \(zone(result.score).advice)")
    }

    /// 점수 눈금. 숫자 하나만 보여주면 "24점이 나쁜 건지"를 알 수 없다 —
    /// 어느 구간에 서 있는지 자리로 보여준다.
    private func scoreScale(_ score: Int) -> some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let ratio = min(max(Double(score) / 100, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [KB.caution, KB.yellow, KB.green],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(height: 8)
                    Circle()
                        .fill(KB.surface)
                        .overlay(Circle().stroke(scoreColor(score), lineWidth: 3))
                        .frame(width: 20, height: 20)
                        .offset(x: (geo.size.width - 20) * ratio)
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                }
                .frame(height: 20)
            }
            .frame(height: 20)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: score)

            HStack {
                ForEach(Self.zones, id: \.label) { zone in
                    Text(zone.label)
                        .font(.kb(10.5))
                        .foregroundStyle(KB.muted)
                        .frame(maxWidth: .infinity,
                               alignment: zone.label == Self.zones.first?.label ? .leading
                                        : (zone.label == Self.zones.last?.label ? .trailing : .center))
                }
            }
        }
    }

    private struct ScoreZone {
        let label: String
        let upperBound: Int
        let advice: String
    }

    private static let zones = [
        ScoreZone(label: "위험", upperBound: 40,
                  advice: "이번 주 계획대로 쓰면 적금 목표를 지키기 어려워요. 아래 조정안 하나만 적용해도 달라져요."),
        ScoreZone(label: "주의", upperBound: 60,
                  advice: "지킬 수는 있지만 여유가 거의 없어요. 예정에 없던 지출이 하나 생기면 넘어가요."),
        ScoreZone(label: "안정", upperBound: 80,
                  advice: "약속과 저축 목표를 함께 지킬 수 있어요. 큰 지출만 미리 챙기면 돼요."),
        ScoreZone(label: "여유", upperBound: 101,
                  advice: "계획에 여유가 있어요. 지금처럼만 쓰면 목표를 지키고도 남아요."),
    ]

    private func zone(_ score: Int) -> ScoreZone {
        Self.zones.first { score < $0.upperBound } ?? Self.zones[Self.zones.count - 1]
    }

    /// 조정안을 적용해 점수가 올랐을 때만 튀어오른다. 화면에 들어올 때는 움직이지 않는다.
    private func celebrate(from before: Int) {
        let gained = model.tuneScore.score - before
        guard gained > 0 else { return }
        gainedPoints = gained
        pop = true
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            pop = false
            try? await Task.sleep(for: .seconds(1.8))
            gainedPoints = 0
        }
    }

    private func scoreColor(_ score: Int) -> Color { KB.score(score) }

    /// 90점 이상은 손댈 게 없다 — 조정안을 늘어놓으면 없는 문제를 만든다.
    @ViewBuilder
    private var candidateSection: some View {
        if model.tuneScore.score >= 90 {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(KB.green)
                Text("지금 계획대로 가면 돼요. 조정할 일정이 없어요.")
                    .font(.kb(14, .medium)).foregroundStyle(KB.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(KB.greenSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("tune-adjustment-comparison")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("조정안 비교")
                    .font(.kb(17, .bold)).foregroundStyle(KB.ink)
                    .accessibilityIdentifier("tune-adjustment-comparison")
                ForEach(model.tuneAdjustmentCandidates) { candidate in
                    candidateRow(candidate)
                }
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
                // 점수가 그대로면 "24 → 24점"은 아무 말도 하지 않는다. 오른 경우에만 적는다.
                if let after = candidate.scoreAfter, after > candidate.scoreBefore {
                    Text("\(candidate.scoreBefore) → \(after)점")
                        .money(12.5).foregroundStyle(KB.green)
                }
            }
            Text(candidateReason(candidate))
                .font(.kb(12.5)).foregroundStyle(KB.muted).fixedSize(horizontal: false, vertical: true)

            if candidate.isExecutable {
                Button {
                    let before = model.tuneScore.score
                    if onApprove(candidate) {
                        celebrate(from: before)
                        onMessage("‘\(candidate.title)’ 조정안을 승인하고 계획을 다시 계산했어요.")
                    }
                } label: {
                    HStack {
                        Text("조정하기")
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

    /// 점수가 안 오르는 조정안에 "가장 많이 회복해요"라고 쓰면 눌러도 아무 일 없어 보인다.
    /// 그때는 실제로 달라지는 것 — 이번 주에 쓸 수 있는 돈 — 으로 말한다.
    private func candidateReason(_ candidate: TuneAdjustmentCandidate) -> String {
        let after = candidate.scoreAfter ?? candidate.scoreBefore
        if candidate.isExecutable, after <= candidate.scoreBefore {
            return "점수는 그대로지만 이번 주에 쓸 수 있는 돈이 \(formatWon(candidate.gain)) 늘어나요."
        }
        return candidate.reason.message
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
