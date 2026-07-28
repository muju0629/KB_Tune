 //
//  MainTabView.swift
//  KB_Tune
//
//  하단 내비게이션: 주간 / 대화 / 분석 / 카드·적금.
//  페이지형 TabView라 화면을 좌우로 스와이프해 탭을 넘길 수 있다(인스타그램식).
//  기본 탭바 대신 브랜드에 맞춘 커스텀 하단바를 쓴다.
//  설정은 계획 화면 상단에서 진입한다.
//

import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var model: AppModel
    /// 손떨림·어지럼 때문에 화면 이동을 줄여 둔 사용자. 남은 전환도 여기서 끈다.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TabView(selection: $model.selectedTab) {
            // 순서는 실제 사용 흐름과 같다 — 이번 주 계획을 보고(주간),
            // 왜 그런지 확인하고(분석), 어떻게 바꿀지 상의하고(대화), 상품으로 간다.
            // 좌우로 밀기만 해도 이 흐름이 그대로 이어진다.
            WeeklyPlanView().tag(MainTab.weekly)
            AnalysisView().tag(MainTab.analysis)
            ChatbotView().tag(MainTab.chat)
            ProductsTabView().tag(MainTab.products)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // 페이지형 TabView는 손으로 밀 때만 따라오고, 코드로 탭을 바꾸면 그냥 잘라 붙인다.
        // 하단 알약은 미끄러지는데 본문만 뚝 끊기던 이유다. 여기에 한 번 걸어 두면
        // 탭바로 누르든 화면 안 버튼으로 넘어가든 항상 같은 속도로 밀린다.
        //
        // 화면이 도착한 뒤에는 아무것도 움직이지 않는다. 손가락이 미는 방향과 화면이
        // 미는 방향을 맞추는 것까지가 이 앱에 필요한 모션이다.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.selectedTab)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 이미 보고 있는 탭을 다시 누르면 그 화면을 처음 상태로 되돌린다.
            CustomTabBar(selected: $model.selectedTab) { tab in
                if tab == .weekly { model.resetPlanView() }
            }
        }
        .tint(KB.ink)
    }
}

/// 브랜드 하단바. iOS 26 리퀴드 글래스 스타일 — 회색 유리 알약이 선택된 탭으로 미끄러진다.
/// 탭 하나만 상태가 바뀌므로 다른 탭은 색만 조용히 따라가고 따로 반응하지 않는다.
struct CustomTabBar: View {
    @Binding var selected: MainTab
    var onReselect: (MainTab) -> Void
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 선택되면 채워진 아이콘으로 바뀐다 — KB Pay를 비롯한 금융 앱의 공통 문법.
    private let items: [(tab: MainTab, label: String, icon: String, onIcon: String)] = [
        (.weekly,   "주간",     "calendar.day.timeline.left", "calendar.day.timeline.left"),
        (.analysis, "분석",     "chart.bar.xaxis", "chart.bar.xaxis"),
        (.chat,     "대화",     "bubble.left.and.bubble.right", "bubble.left.and.bubble.right.fill"),
        (.products, "카드·적금", "creditcard", "creditcard.fill"),
    ]

    private let slide = Animation.spring(response: 0.34, dampingFraction: 0.8)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.tab) { item in
                let isOn = selected == item.tab
                Button {
                    if selected == item.tab { onReselect(item.tab) } else { selected = item.tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: isOn ? item.onIcon : item.icon)
                            .font(.kb(18, isOn ? .semibold : .regular))
                            .contentTransition(.symbolEffect(.replace.offUp))
                            .symbolEffect(.bounce, value: isOn)
                        Text(item.label)
                            .font(.kb(10, isOn ? .semibold : .medium))
                    }
                    .foregroundStyle(isOn ? KB.ink : KB.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if isOn {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.thinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                )
                                .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
                                .matchedGeometryEffect(id: "tabHighlight", in: highlight)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(TabPressStyle())
                .accessibilityLabel("\(item.label) 탭")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .animation(reduceMotion ? nil : slide, value: selected)
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(KB.line.opacity(0.6), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
        .background(KB.canvas.ignoresSafeArea(edges: .bottom))
        .sensoryFeedback(.selection, trigger: selected)
    }
}

/// 탭을 누르는 동안 살짝 눌러지는 반응 — 애플 기본 버튼처럼 은은하게.
private struct TabPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

#Preview {
    MainTabView().environmentObject(AppModel())
}
