//
//  ProductsView.swift
//  KB_Tune
//
//  카드 추천 · 적금/통장 추천 페이지 — 기준서 v2 (2026.07.21).
//  리스트는 가볍게(카드 이미지 + 이름 + 핵심 수치 하나), 근거·조건은 상세로.
//  기준서 필수 표시(예상치≠최대치·충족/미충족·비교 대안·공식링크+검증일)는 상세에서 충족.
//

import SwiftUI

// MARK: - 진입점 (시트 / 탭)

struct ProductsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ProductsHome()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(KB.muted)
                        }
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

struct ProductsTabView: View {
    var body: some View {
        NavigationStack { ProductsHome() }
    }
}

// MARK: - 홈 (카드 | 적금·통장)

struct ProductsHome: View {
    @EnvironmentObject private var model: AppModel
    @State private var segment = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                segmentToggle
                if segment == 0 {
                    CardRecommendPage()
                } else {
                    SavingsRecommendPage()
                }
                footer
            }
            .padding(20)
        }
        .background(KB.canvas)
        .navigationTitle("내 소비에 맞는 금융상품")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var segmentToggle: some View {
        HStack(spacing: 0) {
            segButton("카드 추천", 0)
            segButton("적금·통장", 1)
        }
        .padding(4)
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    private func segButton(_ title: String, _ index: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { segment = index }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: segment == index ? .semibold : .medium))
                .foregroundStyle(KB.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(segment == index ? KB.yellow : .clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(KB.muted)
            Text("검증일 \(productVerifiedAt) 기준 · 가입 전 KB 공식 안내에서 다시 확인해 주세요.")
                .font(.system(size: 11.5)).foregroundStyle(KB.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

// MARK: - 카드 추천 페이지

struct CardRecommendPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var showMore = false

    var body: some View {
        let reco = RecoEngine.evalCards(model)
        let rest = reco.others.count + reco.excluded.count

        VStack(alignment: .leading, spacing: 14) {
            spendSummary(reco)

            if let pick = reco.pick {
                CardHeroRow(eval: pick, badge: "추천", alternative: reco.alternative)
            }
            if let alt = reco.alternative {
                CardHeroRow(eval: alt, badge: "대안", alternative: reco.pick, compact: true)
            }

            if rest > 0 {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { showMore.toggle() }
                } label: {
                    HStack {
                        Text("다른 카드 \(rest)개").font(.system(size: 13, weight: .medium)).foregroundStyle(KB.ink)
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(KB.muted)
                            .rotationEffect(.degrees(showMore ? 180 : 0))
                    }
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KB.line, lineWidth: 1))
                }
                .buttonStyle(.plain)

                if showMore {
                    ForEach(reco.others) { e in
                        NavigationLink { CardDetailView(eval: e, alternative: reco.pick) } label: {
                            CardCandidateRow(eval: e)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(reco.excluded) { e in excludedRow(e) }
                }
            }
        }
    }

    private func spendSummary(_ reco: CardReco) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("7월 일정비 예상").font(.system(size: 12)).foregroundStyle(KB.muted)
                Spacer()
                Text(model.analysisPeriod).font(.system(size: 11)).foregroundStyle(KB.muted)
            }
            Text(formatWon(model.spendMonthly))
                .font(.system(size: 24, weight: .bold)).foregroundStyle(KB.ink)
            TierBar(recognized: reco.recognizedSpend, tiers: [200_000, 300_000, 400_000])
            Text("카드 전월실적이 아니라 캘린더 일정비예요. 실제 실적은 카드 내역에서 확인해 주세요.")
                .font(.system(size: 11)).foregroundStyle(KB.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    private func excludedRow(_ e: CardEval) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "minus.circle").font(.system(size: 14)).foregroundStyle(KB.muted).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.product.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
                Text(e.excludeReason ?? "").font(.system(size: 11.5)).foregroundStyle(KB.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KB.line.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 실적 게이지: 진행 막대 + 구간 칩(20/30/40만). 라벨을 칩으로 분리해 겹침·잘림 없음.
struct TierBar: View {
    let recognized: Int
    let tiers: [Int]
    private var maxScale: Double { Double(tiers.last ?? 400_000) * 1.18 }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geo in
                let ratio = min(1, max(0, CGFloat(Double(recognized) / maxScale)))
                let fillWidth = recognized > 0 ? max(10, geo.size.width * ratio) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(KB.line.opacity(0.5)).frame(height: 8)
                    Capsule().fill(KB.yellow)
                        .frame(width: min(geo.size.width, fillWidth), height: 8)
                }
                .frame(width: geo.size.width, alignment: .leading)
                .clipped()
            }
            .frame(height: 8)
            HStack(spacing: 6) {
                Text("캘린더 기준").font(.system(size: 11)).foregroundStyle(KB.muted)
                ForEach(tiers, id: \.self) { t in
                    let met = recognized >= t
                    HStack(spacing: 2) {
                        if met { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                        Text("\(t / 10_000)만").font(.system(size: 11, weight: met ? .semibold : .regular))
                    }
                    .foregroundStyle(met ? KB.green : KB.muted)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(met ? KB.greenSoft : KB.line.opacity(0.3), in: Capsule())
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// 추천·대안 히어로 카드 — 리스트에선 카드이미지 + 이름 + 순혜택 하나만.
struct CardHeroRow: View {
    let eval: CardEval
    let badge: String
    let alternative: CardEval?
    var compact = false

    var body: some View {
        NavigationLink { CardDetailView(eval: eval, alternative: alternative) } label: {
            HStack(spacing: 14) {
                CardArt(url: eval.product.imageURL, height: compact ? 42 : 56)
                VStack(alignment: .leading, spacing: 4) {
                    // 배지를 이름과 같은 줄에 두면 긴 카드명이 2줄로 깨져 별도 행으로 분리
                    Text(badge)
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(KB.ink)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(badge == "추천" ? KB.yellow : KB.line, in: Capsule())
                    Text(eval.product.name)
                        .font(.system(size: compact ? 14.5 : 16, weight: .bold)).foregroundStyle(KB.ink)
                        .lineLimit(1).minimumScaleFactor(0.85)
                    if !compact {
                        Text(eval.product.short).font(.system(size: 12)).foregroundStyle(KB.muted)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("월 +\(formatWon(eval.netMonthly))")
                            .font(.system(size: compact ? 15 : 19, weight: .bold)).foregroundStyle(KB.green)
                        Text("예상 혜택").font(.system(size: 11)).foregroundStyle(KB.muted)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(KB.muted)
            }
            .padding(16)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(badge == "추천" ? KB.yellow : KB.line, lineWidth: badge == "추천" ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }
}

struct CardCandidateRow: View {
    let eval: CardEval

    var body: some View {
        HStack(spacing: 12) {
            CardArt(url: eval.product.imageURL, height: 34)
            Text(eval.product.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(KB.ink)
            Spacer(minLength: 4)
            Text("월 +\(formatWon(eval.netMonthly))")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(KB.green)
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(KB.muted)
        }
        .padding(.horizontal, 13).frame(height: 56)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
    }
}

/// KB국민카드 공식 카드 플레이트 이미지 (실패 시 아이콘 폴백)
struct CardArt: View {
    let url: String
    var height: CGFloat = 44

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(KB.yellowSoft)
                    .overlay(Image(systemName: "creditcard").font(.system(size: height * 0.4, weight: .light)).foregroundStyle(KB.ink))
                    .aspectRatio(1.58, contentMode: .fit)
            }
        }
        .frame(height: height)
    }
}

// MARK: - 카드 상세

struct CardDetailView: View {
    let eval: CardEval
    let alternative: CardEval?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                benefitBox
                fitLine
                if !eval.unmet.isEmpty { checklist }
                if let alt = alternative, alt.id != eval.id { altBox(alt) }
                cautions
                linkFooter
            }
            .padding(20)
        }
        .background(KB.canvas)
        .navigationTitle(eval.product.kind.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardArt(url: eval.product.imageURL, height: 92)
            VStack(alignment: .leading, spacing: 4) {
                Text(eval.product.name).font(.system(size: 21, weight: .bold)).foregroundStyle(KB.ink)
                Text(eval.product.short).font(.system(size: 13)).foregroundStyle(KB.muted)
            }
            HStack(spacing: 8) {
                metaChip(eval.product.feeNote)
                // 상세로 들어온 카드는 하드필터를 통과한 카드 → 실적 조건 충족 표시
                metaChip(eval.product.spendNote, met: true)
            }
        }
    }

    private func metaChip(_ text: String, met: Bool = false) -> some View {
        HStack(spacing: 3) {
            if met { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(met ? KB.green : KB.ink)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(met ? KB.greenSoft : KB.line.opacity(0.4), in: Capsule())
    }

    // 예상 순혜택(큰 숫자) + 구성 내역 + 최대치 구분
    private var benefitBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("회원님 예상 순혜택 (월)").font(.system(size: 12)).foregroundStyle(KB.muted)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("+\(formatWon(eval.netMonthly))")
                        .font(.system(size: 26, weight: .bold)).foregroundStyle(KB.green)
                    Text("연 약 +\(formatWon(eval.netMonthly * 12))").font(.system(size: 12.5)).foregroundStyle(KB.muted)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(eval.benefitLines, id: \.label) { line in
                    HStack(alignment: .top) {
                        Text(line.label).font(.system(size: 12.5)).foregroundStyle(KB.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(line.amount > 0 ? "+\(formatWon(line.amount))" : "—")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(line.amount > 0 ? KB.green : KB.muted)
                    }
                }
                if eval.product.annualFee > 0 {
                    HStack {
                        Text("연회비 월 환산").font(.system(size: 12.5)).foregroundStyle(KB.ink)
                        Spacer()
                        Text("−\(formatWon(eval.product.annualFee / 12))")
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(KB.caution)
                    }
                }
            }
            Text("최대 \(eval.product.capNote) — 모든 조건 충족 시 상한이며 예상값과 구분해요.")
                .font(.system(size: 11.5)).foregroundStyle(KB.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KB.greenSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // 추천 이유 한 줄(개인화). 리스트에 없던 근거를 여기서만.
    private var fitLine: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 14)).foregroundStyle(KB.ink)
            Text(eval.fitCopy).font(.system(size: 13.5)).foregroundStyle(KB.ink)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KB.yellowSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // 확인이 필요한 조건만(충족 정보는 위 순혜택·칩으로 이미 전달).
    private var checklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("가입 전 확인").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            ForEach(eval.unmet, id: \.self) { c in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 15)).foregroundStyle(KB.caution)
                    Text(c).font(.system(size: 13.5)).foregroundStyle(KB.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func altBox(_ alt: CardEval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("비교 대안").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            NavigationLink { CardDetailView(eval: alt, alternative: nil) } label: {
                CardCandidateRow(eval: alt)
            }
            .buttonStyle(.plain)
        }
    }

    private var cautions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("주의할 점").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            ForEach(eval.product.cautions, id: \.self) { c in
                HStack(alignment: .top, spacing: 8) {
                    Text("·").font(.system(size: 14, weight: .bold)).foregroundStyle(KB.muted)
                    Text(c).font(.system(size: 13)).foregroundStyle(KB.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var linkFooter: some View { ProductLinkFooter(url: eval.product.url, label: "KB국민카드 공식 안내에서 확인") }
}

// MARK: - 적금·통장 추천 페이지

struct SavingsRecommendPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var showExcluded = false

    var body: some View {
        let evals = RecoEngine.evalSavings(model)
        let ex = evals.filter { $0.verdict == .excluded }

        VStack(alignment: .leading, spacing: 14) {
            cashflowSummary

            step(1, "비상금은 묶지 않고 따로")
            rows(evals, [.buffer])

            step(2, "목표 저축은 월급날 자동으로")
            rows(evals, [.pick, .alternative])

            step(3, "정책·장기는 자격·시기 확인")
            rows(evals, [.statusBlocked, .conditional])

            if !ex.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { showExcluded.toggle() }
                } label: {
                    HStack {
                        Text("지금 조건이 맞지 않는 상품 \(ex.count)개")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(KB.ink)
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(KB.muted).rotationEffect(.degrees(showExcluded ? 180 : 0))
                    }
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KB.line, lineWidth: 1))
                }
                .buttonStyle(.plain)

                if showExcluded {
                    ForEach(ex) { e in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "minus.circle").font(.system(size: 14)).foregroundStyle(KB.muted).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.product.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
                                Text(e.fitCopy).font(.system(size: 11.5)).foregroundStyle(KB.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(KB.line.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }

    private var cashflowSummary: some View {
        // 고정비를 빼지 않으면 '여유'가 과장된다 — 확인된 고정비를 한 칸으로 노출한다.
        let free = model.monthlyIncome - BudgetEngine.fixed - model.spendMonthly
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                cashCol("수입", model.monthlyIncome, KB.ink)
                Text("−").font(.system(size: 13)).foregroundStyle(KB.muted).frame(width: 14)
                cashCol("고정비", BudgetEngine.fixed, KB.ink)
                Text("−").font(.system(size: 13)).foregroundStyle(KB.muted).frame(width: 14)
                cashCol("일정비", model.spendMonthly, KB.ink)
                Text("=").font(.system(size: 13)).foregroundStyle(KB.muted).frame(width: 14)
                cashCol("여유", free, KB.green)
            }
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 12)).foregroundStyle(KB.green)
                Text(model.savingsGoal <= free
                     ? "목표 저축 \(formatWon(model.savingsGoal))은 여유 안이라 현금 흐름을 침범하지 않아요."
                     : "목표 저축 \(formatWon(model.savingsGoal))은 여유 \(formatWon(free))보다 커요. 일정비를 줄이거나 목표를 낮춰야 지킬 수 있어요.")
                    .font(.system(size: 12)).foregroundStyle(KB.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    private func cashCol(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(KB.muted)
            // 7자리 금액이 3분할 폭을 넘겨 줄바꿈되지 않게 축소 허용
            Text(formatWon(value)).font(.system(size: 15, weight: .bold)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ n: Int, _ title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(KB.ink)
                .frame(width: 22, height: 22)
                .background(KB.yellow, in: Circle())
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(KB.ink)
        }
        .padding(.top, 4)
    }

    /// 전달한 verdict 순서대로 정렬(추천이 대안보다 항상 먼저)
    private func rows(_ evals: [SavingsEval], _ verdicts: [SavingsVerdict]) -> some View {
        ForEach(verdicts.flatMap { v in evals.filter { $0.verdict == v } }) { e in
            NavigationLink { SavingsDetailView(eval: e) } label: { SavingsRow(eval: e) }
                .buttonStyle(.plain)
        }
    }
}

struct SavingsRow: View {
    let eval: SavingsEval

    private var badge: (String, Color)? {
        switch eval.verdict {
        case .pick: ("추천", KB.yellow)
        case .alternative: ("단기 대안", KB.line)
        case .buffer: ("비상금", KB.greenSoft)
        case .statusBlocked: ("신청기간 종료", KB.cautionSoft)
        case .conditional: ("조건 확인", KB.cautionSoft)
        case .excluded: nil
        }
    }

    // 리스트엔 결과 수치만(굵게) + 전제는 작게. 근거·조건은 상세에서.
    private var metric: (headline: String, sub: String)? {
        switch eval.verdict {
        case .pick, .alternative:
            return ("예상 이자 \(formatWon(eval.estInterest)) (세전)",
                    "월 \(shortWon(eval.monthlyDeposit))원 × \(eval.months)개월")
        case .buffer:
            return ("월 약 \(formatWon(eval.estInterest)) 이자 (세전)", "100만원 보관 기준")
        default:
            return nil
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: eval.product.symbol,
                      background: eval.verdict == .pick ? KB.yellowSoft : KB.greenSoft, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(eval.product.name).font(.system(size: 15, weight: .bold)).foregroundStyle(KB.ink)
                    if let b = badge {
                        Text(b.0).font(.system(size: 10, weight: .bold)).foregroundStyle(KB.ink)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(b.1, in: Capsule())
                    }
                }
                Text("\(eval.product.role.rawValue) · \(eval.product.termLabel)")
                    .font(.system(size: 11.5)).foregroundStyle(KB.muted)
                if let m = metric {
                    Text(m.headline).font(.system(size: 13, weight: .bold)).foregroundStyle(KB.green)
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Text(m.sub).font(.system(size: 11)).foregroundStyle(KB.muted)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(KB.muted)
        }
        .padding(15)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(eval.verdict == .pick ? KB.yellow : KB.line, lineWidth: eval.verdict == .pick ? 1.5 : 1))
    }
}

// MARK: - 적금 상세

struct SavingsDetailView: View {
    let eval: SavingsEval

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let status = eval.product.statusNote { statusBox(status) }
                if eval.estInterest > 0 { interestBox }
                fitLine
                benefitTable
                if !eval.unmet.isEmpty { unmetBox }
                cautions
                linkFooter
            }
            .padding(20)
        }
        .background(KB.canvas)
        .navigationTitle(eval.product.role.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconBadge(systemName: eval.product.symbol, background: KB.yellowSoft, size: 52)
            Text(eval.product.name).font(.system(size: 21, weight: .bold)).foregroundStyle(KB.ink)
            Text(eval.product.rateLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.green)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                metaChip(eval.product.termLabel)
                metaChip(eval.product.payLabel)
            }
        }
    }

    private func metaChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium)).foregroundStyle(KB.ink)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(KB.line.opacity(0.4), in: Capsule())
    }

    private func statusBox(_ status: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark").font(.system(size: 15)).foregroundStyle(KB.caution)
            Text(status).font(.system(size: 13, weight: .medium)).foregroundStyle(KB.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KB.cautionSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var interestBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            if eval.months > 0 {
                Text("월 \(formatWon(eval.monthlyDeposit)) × \(eval.months)개월 (세전)")
                    .font(.system(size: 12)).foregroundStyle(KB.muted)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("예상 이자 \(formatWon(eval.estInterest))")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(KB.green)
                    Text("연 \(String(format: "%.2f", eval.product.expectedRate))%")
                        .font(.system(size: 12)).foregroundStyle(KB.muted)
                }
                Text("모든 우대 충족 시 최대 \(formatWon(eval.maxInterest)) (연 \(String(format: "%.2f", eval.product.maxRate))%) · 원금 \(formatWon(eval.monthlyDeposit * eval.months)) · 중도해지 시 낮은 이율")
                    .font(.system(size: 11.5)).foregroundStyle(KB.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("100만원 보관 기준 (세전)").font(.system(size: 12)).foregroundStyle(KB.muted)
                Text("월 약 \(formatWon(eval.estInterest)) 이자")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(KB.green)
                Text("기본금리 연 0.1% · 우대조건 충족 여부에 따라 크게 달라져요.")
                    .font(.system(size: 11.5)).foregroundStyle(KB.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KB.greenSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var fitLine: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 14)).foregroundStyle(KB.ink)
            Text(eval.fitCopy).font(.system(size: 13.5)).foregroundStyle(KB.ink)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KB.yellowSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var benefitTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("핵심 혜택·우대").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            ForEach(eval.product.benefits, id: \.area) { line in
                HStack(alignment: .top, spacing: 10) {
                    Text(line.area)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(KB.ink)
                        .frame(width: 76, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line.value).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.green)
                        Text(line.condition).font(.system(size: 11.5)).foregroundStyle(KB.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    private var unmetBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("가입 전 확인").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            ForEach(eval.unmet, id: \.self) { c in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 15)).foregroundStyle(KB.caution)
                    Text(c).font(.system(size: 13.5)).foregroundStyle(KB.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var cautions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("주의할 점").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            ForEach(eval.product.cautions, id: \.self) { c in
                HStack(alignment: .top, spacing: 8) {
                    Text("·").font(.system(size: 14, weight: .bold)).foregroundStyle(KB.muted)
                    Text(c).font(.system(size: 13)).foregroundStyle(KB.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var linkFooter: some View { ProductLinkFooter(url: eval.product.url, label: "KB국민은행 공식 안내에서 확인") }
}

// MARK: - 공용 링크 푸터

struct ProductLinkFooter: View {
    let url: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let u = URL(string: url) {
                Link(destination: u) {
                    HStack {
                        Text(label)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(KB.ink)
                    .padding(.horizontal, 16).frame(height: 50)
                    .background(KB.yellow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            Text("검증일 \(productVerifiedAt) 기준 · \(productDisclaimer)")
                .font(.system(size: 11)).foregroundStyle(KB.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    ProductsTabView().environmentObject(AppModel())
}
