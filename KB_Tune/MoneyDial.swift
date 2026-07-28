//
//  MoneyDial.swift
//  KB_Tune
//
//  토스식 금액 휠: 숫자 자체가 위아래로 굴러가는 다이얼.
//  가운데 값이 크고 진하게, 이웃 값은 작고 흐리게. 드래그·플릭(관성)·스냅·스텝 햅틱.
//

import SwiftUI

/// 800,000 → "80만"
func shortWon(_ v: Int) -> String {
    if v >= 10_000 { return "\(v / 10_000)만" }
    return v == 0 ? "0" : "\(v)"
}

struct MoneyDial: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    /// 연속 위치(스텝 인덱스 단위). 드래그 중 소수 값을 가짐.
    @State private var position: CGFloat = 0
    @State private var dragBase: CGFloat? = nil

    private let rowHeight: CGFloat = 46
    private var maxIndex: Int { max(0, (range.upperBound - range.lowerBound) / step) }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack {
                    // 모든 값을 렌더 — 멀어질수록 작고 흐려져 자연히 사라짐
                    ForEach(0...maxIndex, id: \.self) { i in
                        wheelRow(i, size: geo.size)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { g in
                            if dragBase == nil { dragBase = position }
                            // 숫자가 손가락을 따라 움직임 (위로 밀면 큰 값이 올라옴)
                            let raw = (dragBase ?? 0) - g.translation.height / rowHeight
                            position = min(max(raw, 0), CGFloat(maxIndex))
                            let newValue = range.lowerBound + Int(position.rounded()) * step
                            if newValue != value { value = newValue }
                        }
                        .onEnded { g in
                            // 플릭 관성: 예상 도착 지점으로 굴러가서 스냅
                            let predicted = (dragBase ?? position) - g.predictedEndTranslation.height / rowHeight
                            let target = min(max(predicted, 0), CGFloat(maxIndex)).rounded()
                            dragBase = nil
                            value = range.lowerBound + Int(target) * step
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
                                position = target
                            }
                        }
                )
            }
            .frame(height: 190)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.18),
                        .init(color: .black, location: 0.82),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(alignment: .trailing) {
                // 고정 단위 라벨 — 휠에는 숫자만 굴러감
                Text("만원")
                    .font(.kb(13, .medium))
                    .foregroundStyle(KB.muted)
                    .padding(.trailing, 4)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 4) {
                Image(systemName: "chevron.up.chevron.down")
                Text("위아래로 조절")
            }
            .font(.kb(10))
            .foregroundStyle(KB.muted.opacity(0.8))
        }
        .sensoryFeedback(.selection, trigger: value)
        .onAppear {
            position = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / step)
        }
    }

    /// 휠의 한 행 — 숫자만(만원 단위), 중심에서 멀수록 작고 흐리게
    private func wheelRow(_ i: Int, size: CGSize) -> some View {
        let d: CGFloat = abs(CGFloat(i) - position)
        let scale: CGFloat = max(0.55, 1 - 0.17 * d)
        let opacity: Double = d > 2.6 ? 0 : max(0.06, 1 - 0.42 * Double(d))
        let y: CGFloat = size.height / 2 + (CGFloat(i) - position) * rowHeight
        return Text("\((range.lowerBound + i * step) / 10_000)")
            .font(.kb(29, .bold))
            .monospacedDigit()
            .foregroundStyle(KB.ink)
            .scaleEffect(scale)
            .opacity(opacity)
            .position(x: size.width / 2, y: y)
    }
}

#Preview {
    struct Demo: View {
        @State var income = 800_000
        @State var goal = 200_000
        var body: some View {
            HStack(spacing: 14) {
                MoneyDial(value: $income, range: 200_000...5_000_000, step: 100_000)
                MoneyDial(value: $goal, range: 0...1_000_000, step: 50_000)
            }
            .padding()
            .background(KB.canvas)
        }
    }
    return Demo()
}
