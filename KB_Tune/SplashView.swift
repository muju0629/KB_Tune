//
//  SplashView.swift
//  KB_Tune
//
//  시작화면. 브랜드 + 한 줄 소개 + 시작 CTA. 1.8초 후 자동 진행도 지원.
//

import SwiftUI

struct SplashView: View {
    var onContinue: () -> Void

    @State private var appear = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // 일정과 소비를 조율하는 Tune의 성격이 바로 보이는 브랜드 마크
            Image("BrandLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: KB.cardShadow.opacity(0.7), radius: 10, y: 5)
            .scaleEffect(appear ? 1 : 0.8)
            .opacity(appear ? 1 : 0)

            Text("KB Tune")
                .font(.kb(34, .bold))
                .foregroundStyle(KB.ink)
                .padding(.top, 24)

            Text("중요한 소비는 지키고,\n나머지를 조율하는 금융 라이프 에이전트")
                .font(.kb(15))
                .foregroundStyle(KB.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 12)
                .opacity(appear ? 1 : 0)

            Spacer()

            Button(action: onContinue) {
                Text("시작하기")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 24)

            Text("데모 데이터로 바로 체험할 수 있어요")
                .font(.kb(12))
                .foregroundStyle(KB.muted)
                .padding(.top, 12)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KB.canvas)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { appear = true }
        }
    }
}

#Preview {
    SplashView(onContinue: {})
}
