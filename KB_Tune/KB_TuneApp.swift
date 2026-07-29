//
//  KB_TuneApp.swift
//  KB_Tune
//
//  Created by Sungjeh Yoon on 7/21/26.
//

import SwiftUI

@main
struct KB_TuneApp: App {
    var body: some Scene {
        WindowGroup {
            // KB 팔레트(DesignSystem.swift)가 밝을 때와 어두울 때 값을 같이 들고 있어서
            // 기기 설정을 그대로 따라간다.
            ContentView()
                // 공개 통계 기준 금액을 새로 받아 둔다. 분기에 한 번 바뀌는 값이라
                // 실패해도 급하지 않다 — 앱에 넣어 둔 사본으로 그대로 돌아간다.
                .task { await BaselinePrices.refresh() }
        }
    }
}
