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
    /// 한 화면에 한 항목. 세 개를 한 번에 늘어놓으면 스크롤이 길어져 아래 항목은
    /// 읽히지 않고 넘어간다 — 항목마다 멈춰 세우는 편이 고지에도 맞다.
    @State private var index = 0
    @State private var forward = true
    private let scrollTopID = "consent-top"

    private var essentialGranted: Bool { decisions[.essential] == true }
    private var items: [ConsentItem] { ConsentItem.allCases }
    private var current: ConsentItem { items[min(index, items.count - 1)] }
    private var isLast: Bool { index == items.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        Color.clear.frame(height: 1).id(scrollTopID)
                        if index == 0 { intro }
                        card(current)
                        if isLast { rightsNotice }
                        Color.clear.frame(height: 8)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .id(index)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                    ))
                }
                // 항목이 바뀌면 맨 위부터 읽어야 한다. 스크롤 위치를 그대로 두면
                // 다음 고지가 중간부터 보이고, 그건 고지한 게 아니다.
                .onChange(of: index) { _, _ in proxy.scrollTo(scrollTopID, anchor: .top) }
            }

            bottomBar
        }
        .background(KB.canvas)
        .onAppear {
            // 처음 받는 동의는 비워 둔다 — 저장값(기본 false)을 미리 채우면
            // 선택 항목을 한 번도 보지 않고 '거부'로 넘어가게 된다.
            guard ConsentStore.isComplete else { return }
            for item in items {
                decisions[item] = ConsentStore.granted(item)
            }
        }
    }

    // MARK: 머리말 — 온보딩과 같은 진행 막대

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                if index > 0 {
                    Button {
                        forward = false
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { index -= 1 }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.kb(17, .semibold)).foregroundStyle(KB.ink)
                    }
                }
                Text("개인정보 처리 동의")
                    .font(.kb(17, .semibold))
                    .foregroundStyle(KB.ink)
                Spacer()
                Text("\(index + 1) / \(items.count)")
                    .font(.kb(12.5, .medium)).foregroundStyle(KB.muted)
                if let onClose {
                    Button("닫기", action: onClose)
                        .font(.kb(14))
                        .foregroundStyle(KB.muted)
                }
            }
            .frame(height: 22)

            HStack(spacing: 5) {
                ForEach(0..<items.count, id: \.self) { i in
                    Capsule()
                        .fill(i <= index ? KB.yellow : KB.line)
                        .frame(height: 4)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: index)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("세 가지를 따로 여쭤봐요")
                .font(.kb(20, .bold))
                .foregroundStyle(KB.ink)
            Text("필수 하나, 선택 둘이에요. 선택은 거부하셔도 앱의 모든 기능을 그대로 쓸 수 있어요. 화면에 있는 내용이 전문이고, 요약본이 따로 있지 않아요.")
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

    /// 항목마다 답을 하나 고르기 전에는 넘어가지 않는다. 선택 항목도 마찬가지 —
    /// 무응답을 '동의 안 함'으로 흘려보내면 물어본 적이 없는 것과 같다.
    private var canAdvance: Bool {
        current.isRequired ? decisions[current] == true : decisions[current] != nil
    }

    private var bottomBar: some View {
        let enabled = canAdvance && (!isLast || essentialGranted)
        return VStack(spacing: 0) {
            Divider().overlay(KB.line)
            Button {
                guard isLast else {
                    forward = true
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { index += 1 }
                    return
                }
                for (item, value) in decisions {
                    ConsentStore.set(item, value)
                }
                ConsentStore.finish()
                onFinish()
            } label: {
                Text(bottomLabel)
                    .font(.kb(16, .semibold))
                    .foregroundStyle(enabled ? KB.onYellow : KB.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(enabled ? KB.yellow : KB.line)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(KB.surface)
    }

    private var bottomLabel: String {
        if !canAdvance {
            return current.isRequired ? "필수 항목에 동의해 주세요" : "동의 여부를 골라 주세요"
        }
        return isLast ? "동의하고 시작하기" : "다음"
    }
}

#Preview {
    ConsentView(onFinish: {})
}
