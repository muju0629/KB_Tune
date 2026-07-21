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
    @StateObject private var model = AppModel()

    enum Phase { case splash, onboarding, main }
    @State private var phase: Phase = .splash

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

            if phase == .splash {
                SplashView {
                    phase = model.hasOnboarded ? .main : .onboarding
                }
                .transition(.opacity)
                .zIndex(2)
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
