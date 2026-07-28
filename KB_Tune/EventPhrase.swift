//
//  EventPhrase.swift
//  KB_Tune
//
//  대화 문장에서 일정 후보를 뽑아낸다.
//  "7/31에 친구들이랑 강남에서 술 한잔" → 7월 31일 · 술 약속 · 모임 · 25,000원(추정)
//
//  뽑기만 하고 판단은 하지 않는다. 되는지 안 되는지는 예산 엔진이 정한다 —
//  이 파일이 금액까지 판정하면 숫자를 만드는 곳이 둘로 갈라진다.
//

import Foundation

enum EventPhrase {

    struct Draft: Equatable {
        var day: Int            // 통산일
        var title: String
        var category: String
        var amount: Int
        var low: Int
        var high: Int
        var basis: String
        /// 사용자가 금액을 직접 말했는지. 말했으면 추정하지 않고 그 값을 쓴다.
        var amountWasSpoken: Bool
    }

    /// 문장에서 찾을 낱말 → 일정 이름. 위에 있는 것이 먼저 걸린다.
    private static let titles: [(keys: [String], title: String)] = [
        (["술", "한잔", "회식", "뒤풀이", "맥주", "소주"], "술 약속"),
        (["결혼", "축의", "청첩"], "결혼식"),
        (["데이트", "기념일", "200일"], "데이트"),
        (["전시", "미술관"], "전시"),
        (["영화", "공연", "콘서트"], "영화"),
        (["스터디", "팀플"], "카페 스터디"),
        (["카페", "커피"], "카페 약속"),
        (["점심", "런치"], "점심 약속"),
        (["저녁", "디너", "맛집", "식사"], "저녁 약속"),
        (["쇼핑", "옷", "선물"], "쇼핑"),
        (["병원", "의원", "한의원", "치과"], "병원"),
        (["가족"], "가족 모임"),
        (["모임", "약속"], "모임"),
    ]

    private static let weekdays = ["월", "화", "수", "목", "금", "토", "일"]

    /// 날짜와 '무슨 일인지'가 둘 다 있어야 일정 후보로 본다.
    /// 하나라도 없으면 nil — 평범한 질문을 일정 제안으로 오해하지 않기 위해서다.
    static func parse(_ text: String, today: Int = DemoClock.today,
                      history: [SpendRecord]? = nil) -> Draft? {
        let q = text.replacingOccurrences(of: " ", with: "")
        guard let day = day(in: q, today: today), let title = title(in: q) else { return nil }

        let spoken = amount(in: q)
        let e = EventEstimator.estimate(title, history: history)
        return Draft(
            day: day,
            title: title,
            category: e.category,
            amount: spoken ?? e.amount,
            low: spoken ?? e.low,
            high: spoken ?? e.high,
            basis: spoken != nil ? "말씀하신 금액을 그대로 넣었어요." : e.basis,
            amountWasSpoken: spoken != nil
        )
    }

    // MARK: 날짜

    /// 통산일. 데모 기간(7~8월) 밖이면 nil.
    static func day(in text: String, today: Int = DemoClock.today) -> Int? {
        let q = text.replacingOccurrences(of: " ", with: "")

        if q.contains("오늘") { return today }
        // '내일모레'에도 '내일'이 들어 있으므로 더 긴 표현부터 본다.
        if q.contains("모레") { return inRange(today + 2) }
        if q.contains("내일") { return inRange(today + 1) }

        // "7/31" · "7월31일" — 월을 분명히 말했으면 여기서 끝낸다.
        // 아래 '31일' 규칙으로 흘려보내면 "12월 25일"이 이번 달 25일로 둔갑한다.
        if let m = groups(#"(?<!\d)(\d{1,2})[/월](\d{1,2})(?:일)?"#, q),
           let month = Int(m[1]), let dd = Int(m[2]) {
            guard DemoClock.months.contains(month) else { return nil }
            return validSerial(month: month, day: dd)
        }
        // "31일" — 오늘이 든 달 기준
        // 200일 기념의 끝 두 자리 '00일'을 날짜로 오해하지 않게 앞 숫자도 확인한다.
        if let m = groups(#"(?<!\d)(\d{1,2})일"#, q), let dd = Int(m[1]) {
            return validSerial(month: DemoClock.month(of: today), day: dd)
        }
        // "이번주 금요일" · "다음주 토요일"
        if let w = weekdays.firstIndex(where: { q.contains($0 + "요일") }) {
            let base = (q.contains("다음주") || q.contains("담주")) ? today + 7 : today
            return inRange(monday(of: base) + w)
        }
        if q.contains("주말") {
            let base = (q.contains("다음주") || q.contains("담주")) ? today + 7 : today
            return inRange(monday(of: base) + 5)   // 토요일
        }
        return nil
    }

    /// 그 주의 월요일(통산일). 2026년 7월 1일이 수요일이라 +2 만큼 밀려 있다.
    private static func monday(of day: Int) -> Int { day - (day - 1 + 2) % 7 }

    private static func inRange(_ day: Int) -> Int? {
        (1...DemoClock.lastDay).contains(day) ? day : nil
    }

    /// 7월 32일·8월 0일처럼 통산일로 바꾸면 우연히 다른 달에 들어가는 값을 거부한다.
    private static func validSerial(month: Int, day: Int) -> Int? {
        guard day >= 1 else { return nil }
        let serial = DemoClock.serial(month: month, day: day)
        guard DemoClock.range(of: month).contains(serial),
              DemoClock.month(of: serial) == month,
              DemoClock.dayOfMonth(of: serial) == day else { return nil }
        return serial
    }

    // MARK: 금액

    /// "10만원" · "35,000원". 못 찾으면 nil이고, 그때는 추정기가 채운다.
    static func amount(in text: String) -> Int? {
        let q = text.replacingOccurrences(of: " ", with: "")
        if let m = groups(#"(?<!\d)(\d+)만(?:원)?"#, q), let n = Int(m[1]),
           n <= 10_000 { return n * 10_000 }
        if let m = groups(#"(?<!\d)(\d+)천원"#, q), let n = Int(m[1]),
           n <= 100_000 { return n * 1_000 }
        if let m = groups(#"(?<!\d)([\d,]{1,11})원"#, q),
           let value = Int(m[1].replacingOccurrences(of: ",", with: "")),
           value <= 100_000_000 {
            return value
        }
        return nil
    }

    // MARK: 이름

    /// 날짜를 아직 말하지 않은 일정 대화에서 되묻기 위해 활동 이름만 먼저 알아낸다.
    static func recognizedTitle(in text: String) -> String? {
        title(in: text.replacingOccurrences(of: " ", with: ""))
    }

    private static func title(in q: String) -> String? {
        titles.first { $0.keys.contains { q.contains($0) } }?.title
    }

    // MARK: 정규식(글자 모양을 찾는 규칙) 도우미

    private static func groups(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }
}
