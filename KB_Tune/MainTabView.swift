//
//  MainTabView.swift
//  KB_Tune
//
//  하단 내비게이션: 주간 계획 / 캘린더 / 대화
//

import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            WeeklyPlanView()
                .tabItem { Label("계획", systemImage: "calendar.day.timeline.left") }
            AnalysisView()
                .tabItem { Label("분석", systemImage: "chart.bar.xaxis") }
            ChatbotView()
                .tabItem { Label("대화", systemImage: "bubble.left.and.bubble.right") }
            ProductsTabView()
                .tabItem { Label("상품", systemImage: "creditcard") }
            SettingsView()
                .tabItem { Label("설정", systemImage: "gearshape") }
        }
        .tint(KB.ink)
    }
}

#Preview {
    MainTabView().environmentObject(AppModel())
}
