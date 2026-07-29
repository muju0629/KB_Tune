//
//  SearchQuery.swift
//  KB_Tune
//
//  일정 제목 → 웹 검색어.
//
//  **제목의 낱말은 하나도 복사하지 않는다.** 제목에서 읽는 것은 카테고리와 '3박'·'2명'
//  같은 구조 신호뿐이고, 검색어는 아래 코드에 적힌 말로만 새로 조립한다.
//  `제주도 3박4일 여행` → `국내 3박 여행 1인 평균 경비` — 제주도는 어디에도 안 남는다.
//
//  차단 목록(지명을 지우는 방식)이 아니라 허용 목록이다. 지명 사전을 아무리 키워도
//  빠뜨린 하나가 그대로 나가지만, 이 방식은 코드에 없는 말이 나갈 방법이 없다.
//  `AgentService.financialIntent()` 가 질문 원문에 쓰는 것과 같은 원리다.
//

import Foundation

enum SearchQuery {

    /// 검색으로 값을 매길 만한 카테고리와, 그 카테고리에 쓸 검색 문구.
    /// 여기 없는 카테고리는 검색하지 않는다 — 공개 통계 기준값이 이미 있거나,
    /// 검색해도 범위가 안 좁혀지는 것들이다.
    private static let searchable: [String: String] = [
        "여행": "여행 1인 평균 경비",
        "여가": "취미 활동 1회 평균 비용",
        "문화": "공연 관람료 평균",
        "업무·학업": "학원 수강료 평균",
        "경조사": "축의금 평균 금액",
    ]
    // "기타"는 뺐다. 카테고리를 못 잡았다는 뜻인데, 그때 나가던 검색어가
    // `1회 평균 비용` 이었다 — 무엇의 1회인지가 빠져 있어 검색해도 답이 안 나온다.
    // 못 잡았으면 검색하지 말고 금액을 직접 받는 편이 낫다.

    /// 해외 여부만 읽는다. 어느 나라인지는 안 읽고 안 보낸다 —
    /// 나가는 건 아래 두 낱말 중 하나뿐이다.
    private static let overseasMarkers = [
        "해외", "외국", "유럽", "동남아", "일본", "중국", "미국", "대만", "베트남",
        "태국", "괌", "사이판", "하와이", "호주", "캐나다", "싱가포르", "필리핀",
    ]

    /// 검색어와, 그 검색어를 만들 때 읽은 신호. 신호는 화면에 그대로 보여준다 —
    /// 무엇이 나가는지 사용자가 눌러보기 전에 알아야 한다.
    struct Built {
        let query: String
        let signals: [String]
    }

    /// 검색어를 만든다. 검색할 이유가 없으면 nil.
    static func make(title: String, category: String) -> Built? {
        guard let phrase = searchable[category] else { return nil }

        let compact = title.replacingOccurrences(of: " ", with: "")
        var parts: [String] = []
        var signals: [String] = []

        if overseasMarkers.contains(where: { compact.contains($0) }) {
            parts.append("해외")
            signals.append("해외 여부")
        } else if category == "여행" {
            parts.append("국내")
            signals.append("해외 여부")
        }

        if let nights = number(before: "박", in: compact), (1...30).contains(nights) {
            parts.append("\(nights)박")
            signals.append("\(nights)박")
        }

        parts.append(phrase)

        let people = number(before: "명", in: compact).flatMap { (2...20).contains($0) ? $0 : nil }
        if let people {
            // '1인 평균'을 'N인 평균'으로 바꾸지 않는다 — 1인 기준을 받아 앱이 곱한다.
            signals.append("\(people)명")
        }

        return Built(query: parts.joined(separator: " "),
                     signals: ["일정 유형(\(category))"] + signals)
    }

    /// 인원수만큼 곱할 배수. 제목에 인원이 없으면 1.
    static func headcount(in title: String) -> Int {
        let compact = title.replacingOccurrences(of: " ", with: "")
        guard let n = number(before: "명", in: compact), (2...20).contains(n) else { return 1 }
        return n
    }

    /// "3박" 의 3. 붙어 있는 숫자만 읽는다.
    private static func number(before unit: String, in compact: String) -> Int? {
        guard let range = compact.range(of: "[0-9]+" + unit, options: .regularExpression) else {
            return nil
        }
        return Int(compact[range].dropLast(unit.count))
    }
}
