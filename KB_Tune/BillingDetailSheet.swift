//
//  BillingDetailSheet.swift
//  KB_Tune
//
//  결제예정 바를 누르면 열리는 이용내역 시트.
//
//  KB Pay 홈의 '결제예정금액 + 최근이용내역' 구성을 따른다 — 큰 금액을 먼저 보여주고,
//  그 금액이 어떤 결제들로 만들어졌는지 바로 아래에 늘어놓는 순서.
//  카드사 앱과 다른 점은 건마다 소비 카테고리를 붙인다는 것이다.
//  KB_Tune은 이 카테고리로 일정과 소비를 잇기 때문에, 분류 결과를 숨기지 않고 드러낸다.
//

import SwiftUI

struct BillingDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: UUID?

    var body: some View {
        let b = model.billing

        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryCard(b)
                if !b.installments.isEmpty { installmentCard(b) }
                transactionList
            }
            .padding(20)
        }
        .background(KB.canvas)
        .presentationDragIndicator(.visible)
    }

    // MARK: 카드 청구액

    private func summaryCard(_ b: BillingSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Text(b.payLabel).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(KB.ink)
                DDayBadge(days: b.daysUntilPay)
                Spacer()
                Text("KB ALL 카드(2054)").font(.system(size: 11)).foregroundStyle(KB.muted)
            }

            Text("카드 청구액")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(KB.muted)
            CountUpWon(value: b.dueNext, size: 32)

            HStack(spacing: 0) {
                miniStat("이용금액", formatWon(b.usage))
                Divider().frame(height: 26).overlay(KB.line)
                miniStat("이용건수", "\(b.count)건")
                Divider().frame(height: 26).overlay(KB.line)
                miniStat("다음 달 이월", formatWon(b.carryover))
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevatedCard(16)
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(KB.muted)
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.ink)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 할부 — 다음 달로 넘어가는 돈

    private func installmentCard(_ b: BillingSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LabelBadge(text: "할부 진행 중", color: KB.tangerine)
            ForEach(b.installments) { tx in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(tx.merchant).font(.system(size: 14, weight: .semibold)).foregroundStyle(KB.ink)
                        Spacer()
                        Text("총 \(formatWon(tx.amount))").font(.system(size: 12.5)).foregroundStyle(KB.muted)
                    }
                    HStack(spacing: 6) {
                        ForEach(1...tx.installmentMonths, id: \.self) { round in
                            roundChip(round: round, tx: tx)
                        }
                    }
                }
            }
            Text("무이자 할부라 이자는 없지만, 다음 달 카드 청구액에 \(formatWon(b.carryover))이 자동으로 얹혀요.")
                .font(.system(size: 11.5)).foregroundStyle(KB.muted).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevatedCard(16)
    }

    /// 회차별 청구액. 1회차는 이번 결제일이라 노랑, 나머지는 아직 안 온 달.
    private func roundChip(round: Int, tx: CardTransaction) -> some View {
        VStack(spacing: 2) {
            Text("\(round)회차").font(.system(size: 10, weight: .medium))
                .foregroundStyle(round == 1 ? KB.ink : KB.muted)
            Text(formatWon(tx.installmentAmount(round: round)))
                .font(.system(size: 11.5, weight: .bold)).monospacedDigit()
                .foregroundStyle(round == 1 ? KB.ink : KB.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(round == 1 ? KB.yellowSoft : KB.canvas,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: 이용내역

    private var transactionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("이용내역").font(.system(size: 15, weight: .bold)).foregroundStyle(KB.ink)
                Spacer()
                Text(model.billing.periodLabel).font(.system(size: 11.5)).foregroundStyle(KB.muted)
            }
            .padding(.bottom, 12)

            ForEach(Array(BillingCycle.transactions.sorted { $0.day > $1.day }.enumerated()),
                    id: \.element.id) { i, tx in
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        expanded = (expanded == tx.id) ? nil : tx.id
                    }
                } label: {
                    VStack(spacing: 0) {
                        transactionRow(tx)
                        if expanded == tx.id, let match = MatchEngine.bestMatch(for: tx, in: model) {
                            matchDetail(match)
                        }
                    }
                }
                .buttonStyle(.plain)

                if i < BillingCycle.transactions.count - 1 {
                    Divider().overlay(KB.line).padding(.leading, 44)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevatedCard(16)
    }

    // MARK: 일정-거래 매칭 근거 (기획 보고서 8.1)

    /// 왜 이 일정과 이어진다고 봤는지를 사람 말로 보여준다.
    ///
    /// 점수(53점)·기준별 배점(20/25)·환산 방식은 **판정에 쓰는 내부 값**이지
    /// 사용자가 "맞다/아니다"를 고르는 데 필요한 정보가 아니다.
    /// 사용자에게 의미 있는 건 "22분 차이"라는 사실이지 "시간 근접성 20점"이 아니라서,
    /// 근거 문장만 남기고 점수 장치는 화면에서 걷어냈다. 점수 로직은 MatchEngine에 그대로 있다.
    private func matchDetail(_ m: MatchResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                LabelBadge(text: m.verdict.label, color: verdictColor(m.verdict))
                Text(m.event.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(KB.ink)
                Spacer()
            }

            // 계산에 실제로 쓰인 근거만. 정보가 없어 빠진 기준은 말하지 않는다.
            VStack(alignment: .leading, spacing: 5) {
                ForEach(m.criteria.filter { $0.max > 0 }) { c in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "circle.fill").font(.system(size: 3.5))
                            .foregroundStyle(KB.muted).padding(.top, 5.5)
                        Text(c.note).font(.system(size: 12)).foregroundStyle(KB.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if m.verdict == .confirm {
                HStack(spacing: 7) {
                    Button {
                        dismiss()
                    } label: {
                        Text("맞아요, 연결할게요")
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(KB.ink)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(KB.yellow, in: Capsule())
                    }
                    Button {
                        withAnimation { expanded = nil }
                    } label: {
                        Text("관련 없어요")
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(KB.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(.white, in: Capsule())
                            .overlay(Capsule().stroke(KB.line, lineWidth: 1))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(13)
        .background(KB.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.bottom, 9)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func verdictColor(_ v: MatchEngine.Verdict) -> Color {
        switch v {
        case .auto: KB.green
        case .confirm: KB.tangerine
        case .unrelated: KB.muted
        }
    }

    private func transactionRow(_ tx: CardTransaction) -> some View {
        // 가맹점명 → 카테고리. 카드내역 OCR에 쓰는 규칙을 그대로 재사용한다.
        let (category, _) = LocalExtractor.category(for: tx.merchant)
        return HStack(spacing: 11) {
            IconBadge(systemName: AppModel.symbol(for: category), size: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(tx.merchant).font(.system(size: 14, weight: .medium)).foregroundStyle(KB.ink)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text("07.\(String(format: "%02d", tx.day))\(tx.timeLabel.map { " " + $0 } ?? "")")
                        .font(.system(size: 11)).foregroundStyle(KB.muted).monospacedDigit()
                    Text("·").font(.system(size: 11)).foregroundStyle(KB.muted)
                    // 네이버페이·KICC 같은 결제대행은 가맹점을 알 수 없어 '기타'로 떨어진다.
                    // 그냥 두면 큰 금액이 조용히 묻히므로, 분류가 안 됐다는 걸 드러낸다.
                    if category == "기타" {
                        Text("분류 필요")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(KB.caution)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(KB.caution.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2])))
                    } else {
                        Text(category).font(.system(size: 11)).foregroundStyle(KB.muted)
                    }
                    if tx.isKBPay {
                        Text("KB Pay").font(.system(size: 9, weight: .bold)).foregroundStyle(KB.ink)
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(KB.yellow, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(formatWon(tx.amount)).money(14).foregroundStyle(KB.ink)
                if tx.isInstallment {
                    Text("\(tx.installmentMonths)개월 무이자")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(KB.tangerine)
                } else if let m = MatchEngine.bestMatch(for: tx, in: model), m.verdict != .unrelated {
                    // 어떤 일정과 이어질 것 같은지 한 줄로. 자세한 근거는 탭하면 펼쳐진다.
                    HStack(spacing: 3) {
                        Image(systemName: "link").font(.system(size: 8, weight: .bold))
                        Text(m.event.title).lineLimit(1)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(verdictColor(m.verdict))
                }
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}
