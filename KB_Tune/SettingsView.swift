//
//  SettingsView.swift
//  KB_Tune
//
//  설정 탭. 프로필 + 내 계획(수입·저축·방향 편집) + 나한테 더 필요한 소비 + 앱 정보.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    enum EditField: Identifiable { case income, savings; var id: Int { hashValue } }
    @State private var editing: EditField?

    private var savingPct: Int {
        model.monthlyIncome > 0
            ? Int((Double(model.savingsGoal) / Double(model.monthlyIncome) * 100).rounded())
            : 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    profileCard
                    planSection
                    keepsSection
                    calendarBasisSection
                    infoSection
                }
                .padding(20)
            }
            .background(KB.canvas)
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $editing) { editSheet($0) }
    }

    // MARK: 프로필

    private var profileCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(KB.yellow).frame(width: 56, height: 56)
                Text(String(model.userName.prefix(1)))
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(KB.ink)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(model.userName)님").font(.system(size: 18, weight: .bold)).foregroundStyle(KB.ink)
                Text(model.userRole)
                    .font(.system(size: 13)).foregroundStyle(KB.muted)
            }
            Spacer()
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(KB.line, lineWidth: 1))
    }

    // MARK: 내 계획

    private var planSection: some View {
        section("내 계획") {
            settingRow(icon: "banknote", title: "월 수입",
                       value: formatWon(model.monthlyIncome), sub: "기본값 · 직접 확인 필요") { editing = .income }
            rowDivider
            settingRow(icon: "target", title: "월 저축 목표",
                       value: formatWon(model.savingsGoal), sub: "수입의 \(savingPct)%") { editing = .savings }
            rowDivider
            directionRow
        }
    }

    private var directionRow: some View {
        HStack(spacing: 12) {
            rowIcon("arrow.up.arrow.down")
            Text("이번 달 소비 방향").font(.system(size: 14.5)).foregroundStyle(KB.ink)
            Spacer()
            Menu {
                ForEach(SpendDirection.allCases) { d in
                    Button { model.direction = d } label: {
                        if model.direction == d { Label(d.label, systemImage: "checkmark") }
                        else { Text(d.label) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.direction.label).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(KB.ink)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(KB.muted)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .sensoryFeedback(.selection, trigger: model.direction)
    }

    // MARK: 나한테 더 필요한 소비

    private var keepsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("나한테 더 필요한 소비").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            FlowChips(items: keepCandidates.map { (tag: $0.tag, label: $0.label, symbol: $0.symbol) },
                      selected: $model.hobbies)
            Text("예산을 조정할 때 \(model.protectedList) 소비는 줄이지 않고 남겨둬요. 탭해서 바로 바꿀 수 있어요.")
                .font(.system(size: 11.5)).foregroundStyle(KB.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 계산 기준

    private var calendarBasisSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("계산 기준").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            VStack(spacing: 0) {
                basisRow(icon: "calendar", title: "2026년 7월 캘린더", detail: "31일 · 인턴 출근 22일")
                rowDivider
                basisRow(icon: "wonsign.circle", title: "일정별 예상 금액", detail: "제목과 일정 유형으로 계산")
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))

            Text("실제 결제액이 아닌 예상값이에요. 수입과 일정 금액을 수정하면 계획도 다시 계산돼요.")
                .font(.system(size: 11)).foregroundStyle(KB.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func basisRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            rowIcon(icon)
            Text(title).font(.system(size: 14.5)).foregroundStyle(KB.ink)
            Spacer()
            Text(detail).font(.system(size: 11.5)).foregroundStyle(KB.muted)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    // MARK: 앱 정보

    private var infoSection: some View {
        section("앱 정보") {
            infoRow("상품 정보 기준일", productVerifiedAt)
            rowDivider
            infoRow("앱 버전", "1.0.0")
            rowDivider
            VStack(alignment: .leading, spacing: 6) {
                Text("개인정보 안내").font(.system(size: 13, weight: .medium)).foregroundStyle(KB.ink)
                Text(productDisclaimer).font(.system(size: 11.5)).foregroundStyle(KB.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
    }

    // MARK: 편집 시트

    private func editSheet(_ field: EditField) -> some View {
        let isIncome = field == .income
        return SheetContainer(title: isIncome ? "월 수입" : "월 저축 목표") {
            MoneyDial(value: isIncome ? $model.monthlyIncome : $model.savingsGoal,
                      range: isIncome ? 200_000...5_000_000 : 0...1_000_000,
                      step: isIncome ? 100_000 : 50_000)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            if !isIncome {
                Text("수입의 \(savingPct)%예요.")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(KB.green)
                    .frame(maxWidth: .infinity)
            }
            Button { editing = nil } label: { Text("완료") }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: 공용 조각

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            VStack(spacing: 0) { content() }
                .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
        }
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 15)).foregroundStyle(KB.ink).frame(width: 22)
    }

    private var rowDivider: some View { Divider().overlay(KB.line).padding(.leading, 16) }

    private func settingRow(icon: String, title: String, value: String, sub: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                rowIcon(icon)
                Text(title).font(.system(size: 14.5)).foregroundStyle(KB.ink)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(value).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(KB.ink)
                    if let sub { Text(sub).font(.system(size: 11.5)).foregroundStyle(KB.muted) }
                }
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(KB.muted)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 14)).foregroundStyle(KB.ink)
            Spacer()
            Text(value).font(.system(size: 14)).foregroundStyle(KB.muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

#Preview {
    SettingsView().environmentObject(AppModel())
}
