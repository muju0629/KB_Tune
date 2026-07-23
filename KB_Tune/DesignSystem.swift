//
//  DesignSystem.swift
//  KB_Tune
//
//  디자인 토큰 · 공용 스타일. 기준: spending-agent-design-handoff/02_DESIGN_SYSTEM.md
//

import SwiftUI

/// KB Tune 색상 토큰
enum KB {
    static let yellow = Color(hex: 0xFFCC00)      // 주요 버튼 · 선택 · 핵심 일정
    static let yellowSoft = Color(hex: 0xFFF7CF)  // 선택 배경 · 약한 강조
    static let ink = Color(hex: 0x25241F)         // 제목 · 주요 숫자 · 아이콘
    static let canvas = Color(hex: 0xFBFAF7)      // 기본 화면 배경
    static let muted = Color(hex: 0x747168)       // 보조 설명 · 메타 정보
    static let line = Color(hex: 0xE6E2D8)        // 구분선 · 목록 경계
    static let green = Color(hex: 0x3F8A55)       // 목표 유지 · 긍정 결과
    static let greenSoft = Color(hex: 0xEEF5EC)   // 아이콘 배경 · 보호 상태
    static let caution = Color(hex: 0xB4540A)     // 차분한 주의(예산 초과 등) — 오류용 빨강 아님
    static let cautionSoft = Color(hex: 0xFBEEE2) // 주의 배경
    static let expenseRed = Color(hex: 0xD64545)  // 월간 캘린더 등 지출 금액 표기

    // 종이 위에 카드를 얇은 테두리 대신 '깊이'로 띄우는 그림자.
    static let cardShadow = Color(hex: 0x2A2822).opacity(0.07)
}

extension View {
    /// 돈 숫자의 정체성 — 따뜻하고 정확한 라운드 숫자(자릿수 고정으로 흔들림 없음).
    /// 한글(원)은 시스템 서체로 자연히 폴백되고, 숫자만 부드러워진다.
    func money(_ size: CGFloat, weight: Font.Weight = .bold) -> some View {
        font(.system(size: size, weight: weight, design: .rounded)).monospacedDigit()
    }

    /// 떠 있는 카드 표면 — 테두리 대신 부드러운 그림자로 종이 위에 띄운다.
    func elevatedCard(_ radius: CGFloat = 18, fill: Color = .white) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: KB.cardShadow, radius: 12, x: 0, y: 5)
    }
}

extension Color {
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// 86000 -> "86,000"
func decimalString(_ value: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "ko_KR")
    return f.string(from: NSNumber(value: value)) ?? "\(value)"
}

/// 86000 -> "86,000원"
func formatWon(_ value: Int) -> String {
    decimalString(value) + "원"
}

/// 110000, 160000 -> "110,000~160,000원" — 문장 안에서 쓰는 범위(단위는 뒤에 한 번만).
/// 표·요약 줄은 양쪽에 단위를 붙이는 WeeklyPlanView.formatRange 를 쓴다.
func formatWonRange(_ low: Int, _ high: Int) -> String {
    low == high ? formatWon(low) : decimalString(low) + "~" + formatWon(high)
}

// MARK: - 버튼 스타일

/// 기본 CTA: KB Yellow, 높이 ~52
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(KB.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(KB.yellow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: KB.yellow.opacity(configuration.isPressed ? 0.15 : 0.35), radius: 10, x: 0, y: 5)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 보조 CTA: 흰색 + 얇은 회색 테두리
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(KB.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(KB.line, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 공용 소형 컴포넌트

/// 아이콘 원형 배경 (이벤트 노드 · 상품 행)
struct IconBadge: View {
    let systemName: String
    var background: Color = KB.yellowSoft
    var foreground: Color = KB.ink
    var size: CGFloat = 46

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.44, weight: .light))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(background, in: Circle())
    }
}
