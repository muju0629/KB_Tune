//
//  ConnectSheet.swift
//  KB_Tune
//
//  온보딩 1단계의 데이터 연결 — 캘린더와 KB Pay 이용내역.
//
//  캘린더는 EventKit이라 **실제 iOS 시스템 권한 팝업**이 뜬다(읽기 + 쓰기).
//  KB Pay 이용내역은 실제 연동이 아니라 데모라서 시스템 팝업이 뜰 수 없다.
//  시스템 팝업처럼 생긴 화면을 그려 흉내내지 않고, 앱 안의 연결 동의 시트로 만든다 —
//  어떤 항목을 가져오고 무엇을 안 가져오는지 밝히는 게 흉내내기보다 정직하고 설득력 있다.
//

import SwiftUI

// MARK: - 연결 항목 한 줄

struct ConnectRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let state: State
    var action: () -> Void

    enum State { case idle, loading, linked, denied }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(tint.opacity(0.16)).frame(width: 42, height: 42)
                    Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.kb(15, .semibold)).foregroundStyle(KB.ink)
                    Text(detail).font(.kb(12.5)).foregroundStyle(KB.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)
                trailing
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(state == .linked ? KB.green.opacity(0.45) : KB.line, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .disabled(state == .loading || state == .linked)
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .idle:
            Text("연결")
                .font(.kb(13, .bold)).foregroundStyle(KB.ink)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(KB.yellow, in: Capsule())
        case .loading:
            ProgressView().tint(KB.muted)
        case .linked:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 15))
                Text("연결됨").font(.kb(12.5, .semibold))
            }
            .foregroundStyle(KB.green)
        case .denied:
            Text("설정에서 허용")
                .font(.kb(12, .medium)).foregroundStyle(KB.caution)
        }
    }
}

// MARK: - KB Pay 이용내역 연결 동의

/// 무엇을 가져오고 무엇을 안 가져오는지 밝히는 시트.
/// 금융 앱 연동에서 사용자가 실제로 불안해하는 건 "카드번호까지 가져가나?"이므로
/// 가져오지 않는 항목을 함께 보여준다.
struct KBPayConsentSheet: View {
    var onLink: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    private let collected = [
        ("이용일시", "calendar"),
        ("가맹점명", "storefront"),
        ("이용금액 · 할부 개월", "wonsign.circle"),
        ("승인 · 취소 여부", "arrow.uturn.backward.circle"),
    ]
    private let notCollected = ["카드번호", "비밀번호", "CVC", "계좌 잔액"]

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(KB.line).frame(width: 38, height: 5).padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 11) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(KB.yellow)
                                .frame(width: 46, height: 46)
                            Text("KB\nPay").font(.kb(12, .heavy))
                                .multilineTextAlignment(.center).foregroundStyle(KB.ink)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("KB Pay 이용내역을\n불러올까요?")
                                .font(.kb(20, .bold)).foregroundStyle(KB.ink)
                                .lineSpacing(2)
                        }
                        Spacer()
                    }
                    .padding(.top, 14)

                    Text("최근 이용내역을 읽어 소비 패턴을 분석하고, 앞으로의 일정에 쓸 금액을 예측해요.")
                        .font(.kb(13.5)).foregroundStyle(KB.muted).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 11) {
                        Text("가져오는 항목").font(.kb(12.5, .semibold))
                            .foregroundStyle(KB.muted)
                        ForEach(collected, id: \.0) { item in
                            HStack(spacing: 9) {
                                Image(systemName: item.1).font(.system(size: 13))
                                    .foregroundStyle(KB.green).frame(width: 18)
                                Text(item.0).font(.kb(14)).foregroundStyle(KB.ink)
                            }
                        }
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KB.greenSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 9) {
                        Text("가져오지 않는 항목").font(.kb(12.5, .semibold))
                            .foregroundStyle(KB.muted)
                        Text(notCollected.joined(separator: " · "))
                            .font(.kb(14, .medium)).foregroundStyle(KB.ink)
                    }
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KB.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Text("이 화면은 KB AI Challenge 데모예요. 실제 KB Pay 계정에 접속하지 않고, 미리 준비한 이용내역을 씁니다.")
                        .font(.kb(11.5)).foregroundStyle(KB.muted).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 22)
            }

            VStack(spacing: 9) {
                Button {
                    working = true
                    Task {
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        onLink()
                        dismiss()
                    }
                } label: {
                    if working { ProgressView().tint(KB.ink) } else { Text("연결하기") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(working)

                Button { dismiss() } label: { Text("나중에") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .background(KB.canvas)
    }
}
