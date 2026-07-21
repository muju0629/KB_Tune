//
//  SettingsView.swift
//  KB_Tune
//
//  설정 탭. 프로필 + 내 계획(수입·저축·방향 편집) + 지키고 싶은 소비 + 앱 정보.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var calendar = CalendarStore()

    enum EditField: Identifiable { case income, savings; var id: Int { hashValue } }
    @State private var editing: EditField?
    @State private var demoStatus: String?
    @State private var isSeeding = false

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
                    demoSection
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
                Text("만 \(model.userAge)세 · 대학생 · 카페 알바")
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
                       value: formatWon(model.monthlyIncome)) { editing = .income }
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

    // MARK: 지키고 싶은 소비

    private var keepsSection: some View {
        let selected = keepCandidates.filter { model.hobbies.contains($0.tag) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("지키고 싶은 소비").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            if selected.isEmpty {
                Text("아직 선택한 항목이 없어요.").font(.system(size: 13)).foregroundStyle(KB.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
            } else {
                let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(selected, id: \.tag) { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.symbol).font(.system(size: 13))
                            Text(item.label).font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(KB.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(KB.yellowSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(KB.yellow, lineWidth: 1))
                    }
                }
            }
            Text("‘\(model.protectedSummary)’를 기준으로 계획을 조정해요.")
                .font(.system(size: 11.5)).foregroundStyle(KB.muted)
        }
    }

    // MARK: 데모 (기기 캘린더에 모의 일정 심기)

    private var demoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("데모").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            VStack(spacing: 0) {
                Button { seedDemo() } label: {
                    HStack(spacing: 12) {
                        rowIcon("calendar.badge.plus")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("기기 캘린더에 모의 일정 만들기")
                                .font(.system(size: 14.5)).foregroundStyle(KB.ink)
                            Text("아이폰 기본 캘린더에 5건 추가돼요")
                                .font(.system(size: 11.5)).foregroundStyle(KB.muted)
                        }
                        Spacer()
                        if isSeeding { ProgressView().tint(KB.muted) }
                        else { Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(KB.muted) }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .disabled(isSeeding)

                rowDivider

                Button {
                    if let url = URL(string: "calshow://") { UIApplication.shared.open(url) }
                } label: {
                    HStack(spacing: 12) {
                        rowIcon("calendar")
                        Text("캘린더 앱에서 확인하기").font(.system(size: 14.5)).foregroundStyle(KB.ink)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(KB.muted)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
                .buttonStyle(.plain)

                rowDivider

                Button {
                    calendar.removeDemoEvents()
                    demoStatus = "모의 일정을 지웠어요."
                } label: {
                    HStack(spacing: 12) {
                        rowIcon("trash")
                        Text("모의 일정 지우기").font(.system(size: 14.5)).foregroundStyle(KB.ink)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))

            if let demoStatus {
                Text(demoStatus).font(.system(size: 11.5)).foregroundStyle(KB.green)
            }
            Text("데모 일정에만 숨은 표시를 넣어, 지울 때 회원님의 실제 일정은 건드리지 않아요.")
                .font(.system(size: 11)).foregroundStyle(KB.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func seedDemo() {
        isSeeding = true
        demoStatus = nil
        Task {
            if calendar.access != .authorized { await calendar.connect() }

            guard calendar.access == .authorized else {
                // 타임아웃이면 그 사유를, 아니면 권한 거부 안내
                demoStatus = calendar.lastError
                    ?? "캘린더 접근 권한이 필요해요. 설정 앱 → 개인정보 보호 → 캘린더에서 켜주세요."
                isSeeding = false
                return
            }

            let n = calendar.seedDemoEvents()
            demoStatus = n > 0
                ? "기본 캘린더에 모의 일정 \(n)건을 넣었어요."
                : "쓰기 가능한 캘린더가 없어요. 캘린더 앱을 한 번 열어 기본 캘린더를 만든 뒤 다시 시도해 주세요."
            isSeeding = false
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
