//
//  Consent.swift
//  KB_Tune
//
//  개인정보 동의. 원문을 화면에 띄우고, 항목별로 눌러서 받는다.
//
//  왜 항목이 셋인가 — 법이 셋을 나누라고 한다.
//   · 제22조 1·5항: 필수와 선택을 나누고, 선택을 거부해도 서비스를 막지 못한다.
//   · 제23조 1항: 민감정보(건강·종교·정치)는 일반 개인정보와 **분리된** 동의를 받아야 한다.
//     캘린더 일정 제목에 "정형외과 진료"·"성당 모임"이 그대로 들어온다.
//   · 제28조의8: 국외 이전은 받는 자·국가·항목·목적·보유기간·거부권을 알리고 동의를 받는다.
//     외부 모델(OpenAI 등)을 부르는 순간 미국으로 나가는 이전이다.
//
//  '한 번에 동의' 버튼을 두지 않았다. 서울동부지법 2025.6.12. 판결이 약관 체크박스 하나로
//  받은 동의를 실질적 동의가 아니라고 봤다. 항목마다 원문을 보이고 따로 누르게 한다.
//

import Foundation
import SwiftUI

// MARK: - 동의 항목

enum ConsentItem: String, CaseIterable, Identifiable {
    /// 서비스가 성립하려면 반드시 있어야 하는 처리. 거부하면 앱을 쓸 수 없다.
    case essential = "consent.essential.v1"
    /// 일정 제목. 없어도 앱은 전부 동작한다 — 유형을 직접 고르면 된다.
    case sensitive = "consent.sensitive.v1"
    /// 외부 모델 호출(= 국외 이전). 없으면 기기 안 엔진으로만 답한다.
    case overseas = "consent.overseas.v1"

    var id: String { rawValue }

    var isRequired: Bool { self == .essential }

    var title: String {
        switch self {
        case .essential: "개인정보 수집·이용 동의"
        case .sensitive: "민감정보 수집·이용 동의"
        case .overseas: "개인정보 국외 이전 동의"
        }
    }

    var badge: String { isRequired ? "필수" : "선택" }

    /// 목록에서 한 줄로 보여줄 요약. 원문을 대신하지 않는다 — 원문은 아래 `clauses`.
    var summary: String {
        switch self {
        case .essential: "일정 날짜·금액으로 예산을 계산해요"
        case .sensitive: "일정 제목을 읽어 소비 유형을 자동으로 분류해요"
        case .overseas: "외부 AI(미국)에 파생 금액을 보내 답변을 만들어요"
        }
    }

    /// 거부했을 때 실제로 무엇이 달라지는지. 선택 항목에만 쓴다.
    var declineEffect: String? {
        switch self {
        case .essential: nil
        case .sensitive: "동의하지 않아도 앱의 모든 기능을 쓸 수 있어요. 일정의 소비 유형만 직접 고르게 돼요."
        case .overseas: "동의하지 않아도 앱의 모든 기능을 쓸 수 있어요. 답변을 기기 안 엔진이 만들어요."
        }
    }

    /// 고지 원문. (항목, 내용) 쌍으로 두는 이유는 법정 기재사항을 빠뜨리지 않기 위해서다.
    var clauses: [(String, String)] {
        switch self {
        case .essential:
            [
                ("처리하는 사람",
                 "KB Tune 팀. 이 앱을 만들고 운영하는 주체이며, 문의는 앱 정보의 연락처로 받습니다."),
                ("수집하는 항목",
                 """
                 · 일정의 날짜·시간·소비 유형·예상 금액
                 · 직접 입력한 월 수입·저축 목표·고정비
                 · 소비 캡처에서 뽑은 거래 금액·가맹점명·결제 수단
                 · 카드 청구 금액·결제일·할부 이월액
                 · 챗봇에 입력한 질문
                 """),
                ("수집하지 않는 항목",
                 "주민등록번호, 계좌 비밀번호, 카드 전체 번호, 위치, 연락처, 사진첩 전체는 수집하지 않습니다. 이름과 나이는 앱 안에서만 쓰고 어디에도 보내지 않습니다."),
                ("이용 목적",
                 "앞으로 잡힌 일정으로 소비를 예측하고, 주간 예산과 카드 결제일 기준 사용 가능액을 계산하고, 그 근거를 설명하기 위해서입니다."),
                ("보관하는 곳과 기간",
                 """
                 수집한 값은 서버가 아니라 이 기기 안에만 저장합니다. 기기가 잠겨 있는 동안에는 복호화되지 않도록 보호하고, iCloud·iTunes 백업에서도 제외합니다.

                 앱을 삭제하면 함께 지워집니다. 설정의 '데모 초기화'로 언제든 직접 지울 수 있습니다.
                 """),
                ("동의를 거부할 권리와 그 결과",
                 "동의를 거부할 수 있습니다. 다만 이 항목은 예산 계산 자체에 필요한 최소 정보라, 거부하면 서비스를 제공할 수 없습니다."),
            ]

        case .sensitive:
            [
                ("왜 따로 묻는지",
                 "캘린더 일정 제목에는 병원 이름, 종교 시설, 정치 활동처럼 개인정보 보호법 제23조가 민감정보로 정한 내용이 들어올 수 있습니다. 민감정보는 다른 항목과 묶어서 동의받을 수 없어 따로 여쭙습니다."),
                ("수집하는 항목",
                 "캘린더 일정의 제목 원문. (예: '정형외과 진료', '성당 모임')"),
                ("이용 목적",
                 "제목에서 소비 유형과 예상 금액을 자동으로 추정하기 위해서입니다. 예를 들어 '치과 예약'을 자기관리 유형으로 분류합니다."),
                ("어디까지 나가는지",
                 """
                 제목은 이 기기를 벗어나지 않습니다. 외부 AI에 동의하더라도 제목은 보내지 않고, '8월 5일 · 카페 · 20,000원'처럼 유형과 금액으로만 바꿔서 보냅니다.

                 이건 설정이 아니라 코드가 지키는 규칙입니다.
                 """),
                ("보관하는 곳과 기간",
                 "다른 항목과 같은 기기 안 보호 저장소에 두고, 앱을 삭제하면 함께 지워집니다."),
                ("동의를 거부할 권리와 그 결과",
                 "거부할 수 있고, 거부해도 앱의 모든 기능을 그대로 쓸 수 있습니다. 일정을 넣을 때 소비 유형을 직접 고르게 되는 것이 유일한 차이입니다. 나중에 설정에서 켜고 끌 수 있습니다."),
            ]

        case .overseas:
            [
                ("왜 따로 묻는지",
                 "외부 AI 모델은 미국에 있는 회사가 운영합니다. 개인정보가 국경을 넘는 것이라 개인정보 보호법 제28조의8에 따라 아래 내용을 알리고 따로 동의를 받습니다."),
                ("이전받는 자",
                 "OpenAI, L.L.C. (미국) — 앱이 외부 모델을 쓰도록 설정된 경우에 한합니다. 설정을 바꾸지 않으면 아무 곳으로도 나가지 않습니다."),
                ("이전되는 항목",
                 """
                 · 일정의 날짜·소비 유형·금액
                 · 카드 청구 금액·결제일·할부 이월액
                 · 가처분소득·저축 목표·남은 예산 같은 계산된 금액

                 질문한 문장은 두 갈래로 나뉩니다.
                 · 묻고 답하는 질문("이번 주 얼마 남았어?")은 기기가 '예산과 추가 사용 가능액' 같은 의도 라벨로 바꾼 뒤에 보냅니다. 문장 자체는 나가지 않습니다.
                 · 일정을 넣거나 고쳐 달라는 요청("금요일에 치과 예약 넣어줘")은 무엇을 넣을지 알아내야 해서 문장이 그대로 나갑니다. 이 문장에 병원·종교처럼 민감한 말이 들어갈 수 있고, 그 경우 함께 이전됩니다.
                 """),
                ("이전되지 않는 항목",
                 """
                 · 이미 저장된 일정의 제목 — '카페 일정'처럼 유형으로 바꿔서 보냅니다
                 · 이름·나이·연락처·주소·계좌번호·카드번호 — 기기와 서버 양쪽에서 가린 뒤 보냅니다
                 · 소비 캡처 이미지와 거기서 읽은 글자 — 기기 안에서만 처리합니다
                 · 음성 녹음 — 받아쓰기도 기기 안에서만 합니다
                 """),
                ("민감한 말을 보내고 싶지 않다면",
                 "일정을 직접 추가 화면에서 넣으시면 문장이 나가지 않습니다. 대화로 넣는 기능만 문장을 보냅니다."),
                ("이전 시기와 방법",
                 "챗봇에 질문할 때마다 그 순간에, 암호화된 통신(HTTPS)으로 보냅니다. 모아두거나 정기적으로 보내지 않습니다."),
                ("이용 목적",
                 "앱이 이미 계산해 둔 숫자를 자연스러운 문장으로 바꾸기 위해서입니다. 금액을 정하는 것은 기기 안 엔진이고, 외부 모델은 그 숫자를 설명만 합니다. 모델이 지어낸 숫자는 전송 전에 걸러집니다."),
                ("보유·이용 기간",
                 """
                 보낸 내용은 이전받는 자의 정책에 따라 오·남용 점검 목적으로 일정 기간(현재 정책 기준 최대 30일) 보관된 뒤 삭제됩니다.

                 보낸 내용을 모델 학습에 이용하지 않는 조건으로만 사용합니다.
                 """),
                ("동의를 거부할 권리와 그 결과",
                 "거부할 수 있고, 거부해도 앱의 모든 기능을 그대로 쓸 수 있습니다. 답변을 기기 안 엔진이 만들게 되는 것이 차이입니다. 나중에 설정에서 끄면 다음 질문부터 즉시 전송이 멈춥니다."),
            ]
        }
    }
}

// MARK: - 동의 저장

/// 동의 여부와 시점을 남긴다.
///
/// 시점을 같이 남기는 이유 — 언제 무엇에 동의받았는지 증명하지 못하면 동의가 없는 것과
/// 같다. 항목 키에 버전(`.v1`)을 박아둔 것도 같은 이유로, 고지 내용이 바뀌면 키를 올려
/// 예전 동의를 자동으로 무효로 만든다.
nonisolated enum ConsentStore {
    private static let versionKey = "consent.version"
    /// 고지 원문을 고칠 때 올린다. 올리면 모든 사용자에게 동의 화면이 다시 뜬다.
    static let currentVersion = 1

    static func granted(_ item: ConsentItem) -> Bool {
        UserDefaults.standard.bool(forKey: item.rawValue)
    }

    static func grantedAt(_ item: ConsentItem) -> Date? {
        UserDefaults.standard.object(forKey: item.rawValue + ".at") as? Date
    }

    static func set(_ item: ConsentItem, _ value: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(value, forKey: item.rawValue)
        defaults.set(value ? Date() : nil, forKey: item.rawValue + ".at")

        // 외부 AI 동의는 기존 AI 스위치와 같은 뜻이다. 두 값이 어긋나면 동의를 철회했는데도
        // 전송이 이어지는 사고가 나므로, 한쪽을 바꾸면 다른 쪽도 따라가게 묶어 둔다.
        if item == .overseas {
            UserDefaults.standard.set(value, forKey: AIConsent.key)
        }
    }

    /// 필수 항목까지 받았고 고지 버전도 최신인가.
    static var isComplete: Bool {
        granted(.essential) && UserDefaults.standard.integer(forKey: versionKey) == currentVersion
    }

    /// 동의 화면을 끝냈다고 표시. 필수를 받은 경우에만 부른다.
    static func finish() {
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
    }

    /// 전부 되돌린다. 데모를 처음부터 다시 보일 때 쓴다.
    static func reset() {
        let defaults = UserDefaults.standard
        for item in ConsentItem.allCases {
            defaults.removeObject(forKey: item.rawValue)
            defaults.removeObject(forKey: item.rawValue + ".at")
        }
        defaults.removeObject(forKey: versionKey)
        defaults.set(false, forKey: AIConsent.key)
    }
}
