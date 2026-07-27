//
//  EventEditSheet.swift
//  KB_Tune
//
//  일정 하나를 고치거나 지우는 화면.
//
//  금액·시간을 바꾸면 예산 계산이 곧바로 따라 움직인다 — 계산의 입력이
//  화면의 캘린더 자체이기 때문이다(BudgetEngine 참고).
//  삭제는 되돌릴 수 없고 기기 캘린더까지 건드릴 수 있어 한 번 더 확인받는다.
//

import SwiftUI

struct EventEditSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let event: DayEvent
    let dayNumber: Int
    /// 기기 캘린더에 함께 반영하기 위해 상위에서 넘겨준다.
    var calendar: CalendarStore?
    var onDone: (String) -> Void = { _ in }

    @State private var startHour: Double
    @State private var amountText: String
    @State private var confirmingDelete = false

    init(event: DayEvent, dayNumber: Int, calendar: CalendarStore? = nil,
         onDone: @escaping (String) -> Void = { _ in }) {
        self.event = event
        self.dayNumber = dayNumber
        self.calendar = calendar
        self.onDone = onDone
        _startHour = State(initialValue: event.startHour)
        _amountText = State(initialValue: event.amount > 0 ? String(event.amount) : "")
    }

    private var amount: Int { Int(amountText) ?? 0 }
    private var changed: Bool { startHour != event.startHour || amount != event.amount }

    /// 바꾼 값을 넣었을 때 이번 주 사용 가능액이 어떻게 되는지 —
    /// 저장하기 전에 결과를 보여줘야 판단할 수 있다.
    private var previewWeekly: Int {
        let delta = amount - event.amount
        return model.weeklyBudget(for: model.direction, extraCommitted: delta)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    timeField
                    amountField
                    if changed { impactCard }
                    deleteSection
                }
                .padding(20)
            }
            .background(KB.canvas)
            .navigationTitle("일정 수정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }.foregroundStyle(KB.muted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장") { save() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(changed ? KB.ink : KB.muted)
                        .disabled(!changed)
                }
            }
        }
    }

    // MARK: 화면 조각

    private var header: some View {
        HStack(spacing: 11) {
            IconBadge(systemName: event.symbol, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.system(size: 16, weight: .bold)).foregroundStyle(KB.ink)
                Text("7월 \(dayNumber)일 · \(event.category)")
                    .font(.system(size: 12.5)).foregroundStyle(KB.muted)
            }
            Spacer()
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .elevatedCard(16)
    }

    private var timeField: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("시작 시각").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            HStack {
                Text(timeLabel(startHour)).money(20).foregroundStyle(KB.ink)
                Spacer()
                Stepper("", value: $startHour, in: 0...23.5, step: 0.5).labelsHidden()
            }
            .padding(14)
            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KB.line, lineWidth: 1))
            Text("30분 단위로 옮길 수 있어요. 길이(\(Int(event.duration))시간)는 그대로예요.")
                .font(.system(size: 11.5)).foregroundStyle(KB.muted)
        }
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("예상 지출 금액").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            HStack(spacing: 6) {
                TextField("", text: $amountText, prompt: Text("금액을 입력하세요"))
                    .font(.system(size: 16)).keyboardType(.numberPad)
                if !amountText.isEmpty {
                    Text("원").font(.system(size: 16)).foregroundStyle(KB.muted)
                }
            }
            .padding(14)
            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(KB.line, lineWidth: 1))
            if let basis = event.estimateBasis {
                Text(basis).font(.system(size: 11.5)).foregroundStyle(KB.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var impactCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("바꾸면").font(.system(size: 13, weight: .semibold)).foregroundStyle(KB.muted)
            HStack {
                Text("이번 주 사용 가능액").font(.system(size: 13.5)).foregroundStyle(KB.ink)
                Spacer()
                Text(formatWon(model.weeklyBudget)).font(.system(size: 13))
                    .foregroundStyle(KB.muted).strikethrough()
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(KB.muted)
                Text(formatWon(previewWeekly)).money(15)
                    .foregroundStyle(previewWeekly >= model.weeklyBudget ? KB.green : KB.caution)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KB.greenSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var deleteSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button(role: .destructive) { confirmingDelete = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "trash").font(.system(size: 14))
                    Text("이 일정 삭제").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(KB.expenseRed)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(KB.expenseRed.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Text(event.calendarEventID != nil
                 ? "기기 캘린더에서도 함께 지워져요."
                 : "이 일정은 앱에만 있어서, 기기 캘린더는 그대로예요.")
                .font(.system(size: 11.5)).foregroundStyle(KB.muted)
        }
        .padding(.top, 4)
        .confirmationDialog("‘\(event.title)’을 삭제할까요?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { delete() }
            Button("취소", role: .cancel) {}
        } message: {
            Text(event.calendarEventID != nil
                 ? "앱과 기기 캘린더 양쪽에서 지워지고, 되돌릴 수 없어요."
                 : "되돌릴 수 없어요.")
        }
    }

    // MARK: 동작

    private func save() {
        if startHour != event.startHour {
            model.updateEventTime(event, on: dayNumber, startHour: startHour)
            if let id = event.calendarEventID {
                calendar?.reschedule(eventID: id, day: dayNumber, startHour: startHour)
            }
        }
        if amount != event.amount {
            model.updateEventAmount(event, on: dayNumber, amount: amount)
        }
        onDone("‘\(event.title)’을 수정했어요. 이번 주 사용 가능액은 \(formatWon(model.weeklyBudget))이에요.")
        dismiss()
    }

    private func delete() {
        let calendarID = model.deleteEvent(event, on: dayNumber)
        if let calendarID { calendar?.remove(eventID: calendarID) }
        onDone("‘\(event.title)’을 지웠어요. 이번 주 사용 가능액은 \(formatWon(model.weeklyBudget))이에요.")
        dismiss()
    }

    private func timeLabel(_ hour: Double) -> String {
        String(format: "%02d:%02d", Int(hour), Int((hour - Double(Int(hour))) * 60))
    }
}
