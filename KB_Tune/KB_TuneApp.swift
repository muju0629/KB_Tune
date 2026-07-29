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
            ContentView()
                // KB 팔레트(DesignSystem.swift)는 밝은 화면 하나만 정의한다.
                // 기기가 다크모드면 커스텀 색은 그대로 밝게 남는데 탭바·입력창·키보드 같은
                // 시스템 컴포넌트만 어두워져, 크림색 본문 아래 검은 탭바가 붙는 화면이 된다.
                // 다크 팔레트를 제대로 만들기 전까지는 밝은 화면으로 고정한다.
                .preferredColorScheme(.light)
                // 공개 통계 기준 금액을 새로 받아 둔다. 분기에 한 번 바뀌는 값이라
                // 실패해도 급하지 않다 — 앱에 넣어 둔 사본으로 그대로 돌아간다.
                .task { await BaselinePrices.refresh() }
        }
    }
}
