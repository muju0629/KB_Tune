//
//  CalendarImportView.swift
//  KB_Tune
//
//  캘린더 정보 가져오기. 기기 캘린더(EventKit) 권한 요청 → 이번 주 일정 로드.
//  기준: prompts/06(권한 설명), 07(빈/로딩/실패 상태)
//

import SwiftUI
import UIKit

struct CalendarImportView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var calendar = CalendarStore()

    var body: some View {
        NavigationStack {
            ZStack {
                KB.canvas.ignoresSafeArea()
                content
            }
            .navigationTitle("캘린더")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch calendar.access {
        case .notDetermined:
            rationale
        case .denied:
            deniedState
        case .authorized:
            authorizedState
        }
    }

    // MARK: 권한 요청 전 — 왜 필요한지 설명

    private var rationale: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 60, weight: .thin))
                .foregroundStyle(KB.yellow)

            Text("일정을 불러오면\n예상 지출을 함께 계산해요")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(KB.ink)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 22)

            Text("이번 주 약속·모임을 읽어와, 각 일정에 예상 지출을 붙이고 사용 가능액을 다시 계산해요. 캘린더 내용은 기기에서만 사용해요.")
                .font(.system(size: 13.5))
                .foregroundStyle(KB.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 34)
                .padding(.top, 12)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    Task { await calendar.connect() }
                } label: {
                    if calendar.isLoading {
                        ProgressView().tint(KB.ink)
                    } else {
                        Text("캘린더 불러오기")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(calendar.isLoading)

                Button {
                    // 데모 데이터로 계속
                    calendar.access = .authorized
                } label: { Text("데모 일정으로 계속하기") }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    // MARK: 거부 상태 — 설정 유도 + 데모 폴백

    private var deniedState: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(KB.muted)
            Text("캘린더 접근이 꺼져 있어요")
                .font(.system(size: 20, weight: .bold)).foregroundStyle(KB.ink)
                .padding(.top, 20)
            Text("설정에서 캘린더 접근을 켜면 실제 일정으로 계획을 세울 수 있어요. 지금은 데모 일정으로 계속할 수 있어요.")
                .font(.system(size: 13.5)).foregroundStyle(KB.muted)
                .multilineTextAlignment(.center).lineSpacing(3)
                .padding(.horizontal, 34).padding(.top, 12)
            Spacer()
            VStack(spacing: 12) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: { Text("설정 열기") }
                .buttonStyle(PrimaryButtonStyle())

                Button { calendar.access = .authorized } label: { Text("데모 일정으로 계속하기") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
    }

    // MARK: 허용 상태 — 이번 주 일정 목록

    private var authorizedState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 요약 헤더
                VStack(alignment: .leading, spacing: 6) {
                    Text("이번 주 일정")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(KB.ink)
                    Text("불러온 일정에 예상 지출을 붙여 계획에 반영해요.")
                        .font(.system(size: 13)).foregroundStyle(KB.muted)
                }
                .padding(.top, 8)

                // 기기 캘린더에서 읽어온 일정
                if !calendar.events.isEmpty {
                    sectionLabel("내 캘린더에서 불러옴", count: calendar.events.count)
                    ForEach(calendar.events) { ev in eventRow(ev) }
                }

                // 계획 지출 일정 (항상 표시)
                sectionLabel("KB Tune 계획 일정", count: model.weekSpendItems.count)
                ForEach(model.weekSpendItems) { item in
                    eventRow(PlanEvent(title: item.title, amount: item.amount,
                                       symbol: item.symbol, dayLabel: item.dayLabel,
                                       featured: item.isRisky))
                }

                // 기기 일정이 없을 때 안내
                if calendar.didFetch && calendar.events.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle").foregroundStyle(KB.muted)
                        Text("이번 주 기기 캘린더에 등록된 일정이 없어요. 데모 계획 일정으로 이어서 볼 수 있어요.")
                            .font(.system(size: 12.5)).foregroundStyle(KB.muted)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KB.greenSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                // 다시 불러오기
                Button { calendar.fetchThisWeek() } label: {
                    HStack { Image(systemName: "arrow.clockwise"); Text("캘린더 다시 불러오기") }
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(KB.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KB.line, lineWidth: 1))
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            Spacer()
            Text("\(count)건").font(.system(size: 12)).foregroundStyle(KB.muted)
        }
    }

    private func eventRow(_ ev: PlanEvent) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemName: ev.symbol,
                      background: ev.fromDeviceCalendar ? KB.line.opacity(0.4) : (ev.featured ? KB.yellowSoft : KB.greenSoft))
            VStack(alignment: .leading, spacing: 3) {
                Text(ev.title).font(.system(size: 15, weight: .medium)).foregroundStyle(KB.ink).lineLimit(1)
                Text(ev.dayLabel).font(.system(size: 12)).foregroundStyle(KB.muted)
            }
            Spacer()
            if ev.amount > 0 {
                Text(formatWon(ev.amount)).font(.system(size: 14, weight: .semibold)).foregroundStyle(KB.ink)
            } else {
                Text("지출 미정").font(.system(size: 12.5)).foregroundStyle(KB.muted)
            }
        }
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(KB.line, lineWidth: 1))
    }
}

#Preview {
    CalendarImportView().environmentObject(AppModel())
}
