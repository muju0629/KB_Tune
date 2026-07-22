 //
//  MainTabView.swift
//  KB_Tune
//
//  하단 내비게이션: 주간 / 대화 / 분석 / 카드·적금.
//  설정은 계획 화면 상단에서 진입한다.
//

import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            WeeklyPlanView()
                .tabItem { Label("주간", systemImage: "calendar.day.timeline.left") }
            ChatbotView()
                .tabItem { Label("대화", systemImage: "bubble.left.and.bubble.right") }
            AnalysisView()
                .tabItem { Label("분석", systemImage: "chart.bar.xaxis") }
            ProductsTabView()
                .tabItem { Label("카드·적금", systemImage: "creditcard") }
        }
        .tint(KB.ink)
    }
}

#Preview {
    MainTabView().environmentObject(AppModel())
}
