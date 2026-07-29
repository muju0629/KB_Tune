//
//  ConsentView.swift
//  KB_Tune
//
//  최초 실행 시 뜨는 동의 화면. 요약이 아니라 **고지 원문을 그대로** 펼쳐 두고,
//  항목마다 따로 누르게 한다.
//
//  접어두지 않은 이유 — 접힌 원문은 읽지 않은 원문이다. 서울동부지법 2025.6.12. 판결이
//  "이용자가 충분히 인지할 수 있는 방식"을 요구했고, 링크 뒤에 숨긴 약관은 그 방식이
//  아니라고 봤다. 스크롤은 길어지지만 그게 고지다.
//

import SwiftUI

struct ConsentView: View {
    /// 필수 동의를 받고 화면을 닫을 때 부른다.
    var onFinish: () -> Void
    /// 설정에서 다시 열었을 때는 닫기 버튼이 필요하다. 최초 실행에서는 nil.
    var onClose: (() -> Void)? = nil

    @State private var decisions: [ConsentItem: Bool] = [:]

    private var essentialGranted: Bool { decisions[.essential] == true }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(KB.line)

            ScrollView {
                VStack(spacing: 14) {
                    intro
                    ForEach(ConsentItem.allCases) { item in
                        card(item)
                    }
                    rightsNotice
                    Color.clear.frame(height: 8)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
            }

            bottomBar
        }
        .background(KB.canvas)
        .onAppear {
            for item in ConsentItem.allCases {
                decisions[item] = ConsentStore.granted(item)
            }
        }
    }

    // MARK: 머리말

    private var header: some View {
        HStack {
            Text("개인정보 처리 동의")
                .font(.kb(17, .semibold))
                .foregroundStyle(KB.ink)
            Spacer()
            if let onClose {
                Button("닫기", action: onClose)
                    .font(.kb(14))
                    .foregroundStyle(KB.muted)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("세 가지를 따로 여쭤봐요")
                .font(.kb(20, .bold))
                .foregroundStyle(KB.ink)
            Text("필수 하나, 선택 둘이에요. 선택은 거부하셔도 앱의 모든 기능을 그대로 쓸 수 있어요. 아래 내용이 전문이고, 요약본이 따로 있지 않아요.")
                .font(.kb(13))
                .foregroundStyle(KB.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    // MARK: 항목 카드

    private func card(_ item: ConsentItem) -> some View {
        let decided = decisions[item]

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text(item.badge)
                        .font(.kb(11, .semibold))
                        .foregroundStyle(item.isRequired ? KB.onYellow : KB.muted)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(item.isRequired ? KB.yellow : KB.line,
                                    in: Capsule())
                    Text(item.title)
                        .font(.kb(15.5, .semibold))
                        .foregroundStyle(KB.ink)
                    Spacer(minLength: 0)
                    if decided == true {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.kb(15))
                            .foregroundStyle(KB.green)
                    }
                }
                Text(item.summary)
                    .font(.kb(12.5))
                    .foregroundStyle(KB.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 13)

            // 고지 원문
            VStack(alignment: .leading, spacing: 13) {
                ForEach(Array(item.clauses.enumerated()), id: \.offset) { _, clause in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(clause.0)
                            .font(.kb(12, .semibold))
                            .foregroundStyle(KB.ink)
                        Text(clause.1)
                            .font(.kb(12))
                            .foregroundStyle(KB.muted)
                            .lineSpacing(3.5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(KB.canvas)

            decisionButtons(item)
                .padding(16)
        }
        .background(KB.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(decided == true ? KB.green.opacity(0.45) : KB.line, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func decisionButtons(_ item: ConsentItem) -> some View {
        let decided = decisions[item]

        VStack(spacing: 9) {
            HStack(spacing: 9) {
                if !item.isRequired {
                    choice("동의하지 않음", selected: decided == false, accent: false) {
                        decisions[item] = false
                    }
                }
                choice("동의합니다", selected: decided == true, accent: true) {
                    decisions[item] = true
                }
            }

            if let effect = item.declineEffect, decided == false {
                Text(effect)
                    .font(.kb(11.5))
                    .foregroundStyle(KB.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if item.isRequired && decided != true {
                Text("이 항목에 동의하지 않으면 예산을 계산할 수 없어 서비스를 제공할 수 없어요.")
                    .font(.kb(11.5))
                    .foregroundStyle(KB.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func choice(_ label: String, selected: Bool, accent: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.kb(14, .semibold))
                .foregroundStyle(selected ? (accent ? KB.onYellow : KB.ink) : KB.muted)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(selected ? (accent ? KB.yellow : KB.line) : KB.canvas)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(selected ? Color.clear : KB.line, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: 권리 안내 (제35~37조)

    private var rightsNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("언제든 하실 수 있는 것")
                .font(.kb(13, .semibold))
                .foregroundStyle(KB.ink)
            Text("""
                 · 동의 철회 — 설정 화면의 '개인정보'에서 선택 항목을 끄면 다음 요청부터 즉시 반영돼요.
                 · 열람·정정 — 저장된 값은 모두 앱 화면에서 직접 보고 고칠 수 있어요.
                 · 삭제 — 설정의 '데모 초기화'로 지우거나, 앱을 삭제하면 함께 지워져요.
                 · 처리 정지 — 필수 항목까지 철회하시려면 앱을 삭제해 주세요. 기기 밖에 사본이 없어요.
                 """)
                .font(.kb(12))
                .foregroundStyle(KB.muted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(KB.greenSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: 하단

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(KB.line)
            Button {
                for (item, value) in decisions {
                    ConsentStore.set(item, value)
                }
                ConsentStore.finish()
                onFinish()
            } label: {
                Text(essentialGranted ? "동의하고 시작하기" : "필수 항목에 동의해 주세요")
                    .font(.kb(16, .semibold))
                    .foregroundStyle(essentialGranted ? KB.onYellow : KB.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(essentialGranted ? KB.yellow : KB.line)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!essentialGranted)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(KB.surface)
    }
}

#Preview {
    ConsentView(onFinish: {})
}
