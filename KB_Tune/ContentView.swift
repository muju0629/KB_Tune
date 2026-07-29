//
//  ContentView.swift
//  KB_Tune
//
//  앱 진입 · 화면 전환 컨트롤러: 시작화면 → 온보딩(랜딩/세팅) → 메인 탭
//
//  전환 구조: 레이어드 ZStack. 메인 탭은 transition 없이(.identity) 아래에 깔리고,
//  위 레이어(온보딩/스플래시)가 페이드아웃하며 걷히는 방식.
//  (TabView를 transition에 태우면 화면이 멈추는 SwiftUI 이슈 회피)
//

import SwiftUI

struct ContentView: View {
    @StateObject private var model: AppModel

    enum Phase { case splash, consent, onboarding, main }
    @State private var phase: Phase

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-test-date-22") {
            DemoClock.fixedToday = 22
        }

        let appModel = AppModel()
        if let current = appModel.thisWeekBudget?.carriesForward {
            if arguments.contains("-ui-test-budget-positive") {
                appModel.openingRollover += 100_000 - current
            } else if arguments.contains("-ui-test-budget-zero") {
                appModel.openingRollover -= current
            } else if arguments.contains("-ui-test-budget-negative") {
                appModel.openingRollover += -100_000 - current
            }
        }
        _model = StateObject(wrappedValue: appModel)

        let startsOnMain = arguments.contains("-ui-test-main")
        _phase = State(initialValue: startsOnMain ? .main : .splash)
        #else
        _model = StateObject(wrappedValue: AppModel())
        _phase = State(initialValue: .splash)
        #endif
    }

    var body: some View {
        ZStack {
            KB.canvas.ignoresSafeArea()

            if phase == .main {
                MainTabView()
                    .transition(.identity) // TabView는 애니메이션 없이 즉시 삽입
            }

            if phase == .onboarding {
                OnboardingView(
                    onFinish: {
                        model.hasOnboarded = true
                        phase = .main
                    },
                    onBack: { phase = .splash }
                )
                .transition(.opacity.combined(with: .scale(scale: 1.03)))
                .zIndex(1)
            }

            // 동의는 온보딩보다 앞이다. 온보딩 첫 단계가 캘린더 연결이라, 동의를 뒤에 두면
            // 일정 제목을 이미 읽은 다음에 민감정보 동의를 묻게 된다.
            if phase == .consent {
                ConsentView(onFinish: {
                    phase = model.hasOnboarded ? .main : .onboarding
                })
                .transition(.opacity)
                .zIndex(2)
            }

            if phase == .splash {
                SplashView {
                    guard ConsentStore.isComplete else {
                        phase = .consent
                        return
                    }
                    phase = model.hasOnboarded ? .main : .onboarding
                }
                .transition(.opacity)
                .zIndex(3)
            }
        }
        .animation(.smooth(duration: 0.5), value: phase)
        .environmentObject(model)
        .tint(KB.ink)
    }
}

#Preview {
    ContentView()
}
