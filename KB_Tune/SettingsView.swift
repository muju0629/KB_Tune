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
    @State private var showResetConfirm = false

    /// AgentService의 동의 키와 같은 값을 본다 — 여기서 끄면 전송도 즉시 멈춘다.
    @AppStorage(CloudAIConsent.key) private var usesCloudAI = false
    /// 웹 검색은 나가는 곳이 달라(검색 엔진) 동의를 따로 받는다.
    @AppStorage(WebSearchConsent.key) private var usesWebSearch = false

    private var savingPct: Int {
        model.monthlyIncome > 0
            ? Int((Double(model.savingsGoal) / Double(model.monthlyIncome) * 100).rounded())
            : 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if model.storageRecoveryNeeded { storageRecoveryWarning }
                    profileCard
                    planSection
                    keepsSection
                    calendarBasisSection
                    privacySection
                    infoSection
                    demoResetSection
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

    private var storageRecoveryWarning: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(KB.caution)
            VStack(alignment: .leading, spacing: 4) {
                Text("기존 저장본을 보호하고 있어요")
                    .font(.kb(14, .semibold)).foregroundStyle(KB.ink)
                Text("읽지 못한 파일을 새 데모 데이터로 덮어쓰지 않았어요. 앱을 업데이트한 뒤 다시 열거나, 아래에서 직접 데모 상태로 초기화해 주세요.")
                    .font(.kb(11.5)).foregroundStyle(KB.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(KB.yellowSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(KB.caution.opacity(0.35), lineWidth: 1))
    }

    // MARK: 프로필

    private var profileCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(KB.yellow).frame(width: 56, height: 56)
                Text(String(model.userName.prefix(1)))
                    .font(.kb(22, .bold)).foregroundStyle(KB.ink)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(model.userName)님").font(.kb(18, .bold)).foregroundStyle(KB.ink)
                Text(model.userRole)
                    .font(.kb(13)).foregroundStyle(KB.muted)
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
            Text("이번 달 소비 방향").font(.kb(14.5)).foregroundStyle(KB.ink)
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
                    Text(model.direction.label).font(.kb(14.5, .semibold)).foregroundStyle(KB.ink)
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
            Text("나한테 더 필요한 소비").font(.kb(13, .semibold)).foregroundStyle(KB.muted)
            FlowChips(items: keepCandidates.map { (tag: $0.tag, label: $0.label, symbol: $0.symbol) },
                      selected: $model.hobbies)
            Text("예산을 조정할 때 \(model.protectedList) 소비는 줄이지 않고 남겨둬요. 탭해서 바로 바꿀 수 있어요.")
                .font(.kb(11.5)).foregroundStyle(KB.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 계산 기준

    private var calendarBasisSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("계산 기준").font(.kb(13, .semibold)).foregroundStyle(KB.muted)
            VStack(spacing: 0) {
                basisRow(icon: "calendar", title: "2026년 7월 캘린더", detail: "31일 · 인턴 출근 22일")
                rowDivider
                basisRow(icon: "wonsign.circle", title: "일정별 예상 금액", detail: "제목과 일정 유형으로 계산")
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))

            Text("실제 결제액이 아닌 예상값이에요. 수입과 일정 금액을 수정하면 계획도 다시 계산돼요.")
                .font(.kb(11)).foregroundStyle(KB.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func basisRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            rowIcon(icon)
            Text(title).font(.kb(14.5)).foregroundStyle(KB.ink)
            Spacer()
            Text(detail).font(.kb(11.5)).foregroundStyle(KB.muted)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    // MARK: 개인정보

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("개인정보").font(.kb(13, .semibold)).foregroundStyle(KB.muted)
            VStack(spacing: 0) {
                Toggle(isOn: $usesCloudAI) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("클라우드 AI 분석")
                            .font(.kb(14.5)).foregroundStyle(KB.ink)
                        Text(usesCloudAI ? "질문 원문·실명 없이 필요한 집계값만 전달" : "기기 안의 예산·패턴 엔진만 사용")
                            .font(.kb(11.5)).foregroundStyle(usesCloudAI ? KB.green : KB.muted)
                    }
                }
                .tint(KB.green)
                .padding(.horizontal, 16).padding(.vertical, 12)

                Divider().padding(.leading, 16)

                Toggle(isOn: $usesWebSearch) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("모르는 일정은 웹에서 찾기")
                            .font(.kb(14.5)).foregroundStyle(KB.ink)
                        Text(usesWebSearch
                             ? "‘국내 3박 여행 1인 평균 경비’처럼 앱이 만든 문장만 검색해요"
                             : "여행처럼 기준이 없는 일정은 금액을 직접 넣어요")
                            .font(.kb(11.5)).foregroundStyle(usesWebSearch ? KB.green : KB.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(KB.green)
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))

            Text("기본은 ‘기기 안에서만’이에요. 클라우드 AI를 켜도 질문 원문·실명·일정 제목은 보내지 않고, 답변에 필요한 날짜·유형·금액과 재무 집계값만 전달해요.")
                .font(.kb(11)).foregroundStyle(KB.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 앱 정보

    private var infoSection: some View {
        section("앱 정보") {
            infoRow("상품 정보 기준일", productVerifiedAt)
            rowDivider
            infoRow("앱 버전", "1.0.0")
            rowDivider
            VStack(alignment: .leading, spacing: 6) {
                Text("개인정보 안내").font(.kb(13, .medium)).foregroundStyle(KB.ink)
                Text(productDisclaimer).font(.kb(11.5)).foregroundStyle(KB.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
    }

    // MARK: 데모 초기화

    /// 넣은 일정·바꾼 설정은 기기에 남는다. 시연을 처음부터 다시 하려면 되돌릴 길이 있어야 한다.
    private var demoResetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { showResetConfirm = true } label: {
                HStack(spacing: 12) {
                    rowIcon("arrow.counterclockwise")
                    Text("데모 상태로 되돌리기").font(.kb(14.5)).foregroundStyle(KB.ink)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
            }
            Text("넣은 일정과 바꾼 설정을 지우고 처음 상태로 돌아가요. 기기 캘린더의 일정은 그대로예요.")
                .font(.kb(11)).foregroundStyle(KB.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert("데모 상태로 되돌릴까요?", isPresented: $showResetConfirm) {
            Button("취소", role: .cancel) { }
            Button("되돌리기", role: .destructive) { model.resetToDemo() }
        } message: {
            Text("이 기기에 저장된 일정·금액·설정이 지워져요. 되돌릴 수 없어요.")
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
                    .font(.kb(13, .medium)).foregroundStyle(KB.green)
                    .frame(maxWidth: .infinity)
            }
            Button { editing = nil } label: { Text("완료") }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: 공용 조각

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.kb(13, .semibold)).foregroundStyle(KB.muted)
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
                Text(title).font(.kb(14.5)).foregroundStyle(KB.ink)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(value).font(.kb(14.5, .semibold)).foregroundStyle(KB.ink)
                    if let sub { Text(sub).font(.kb(11.5)).foregroundStyle(KB.muted) }
                }
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(KB.muted)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.kb(14)).foregroundStyle(KB.ink)
            Spacer()
            Text(value).font(.kb(14)).foregroundStyle(KB.muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

#Preview {
    SettingsView().environmentObject(AppModel())
}
