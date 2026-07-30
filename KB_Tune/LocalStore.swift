//
//  LocalStore.swift
//  KB_Tune
//
//  앱을 껐다 켜도 남아야 하는 상태를 기기에 저장한다.
//
//  서버에는 아무것도 남기지 않는다 — 소비 금액·일정·설정은 사용자 기기에만 있다.
//  형식은 JSON 파일 한 장이다. 3개월을 써도 수백 KB에 그치고, 스키마 이전 장치가
//  필요할 만큼 구조가 복잡하지 않아서 데이터베이스를 둘 이유가 없다.
//

import Foundation

/// 저장 대상.
///
/// 화면 상태(선택된 탭·보고 있는 달)는 넣지 않는다 — 다시 열면 처음 화면부터가 자연스럽다.
/// 파생값(protectedTags·interestTags)도 넣지 않는다. hobbies 에서 다시 계산된다.
struct PersistedState: Codable {
    /// 저장 형식이 바뀌면 올린다. 값이 다르면 불러오지 않고 시드로 시작한다 —
    /// 옛 형식을 억지로 읽어 화면이 깨지느니 데모 상태로 돌아가는 편이 낫다.
    static let currentVersion = 1
    var version = currentVersion

    var hasOnboarded: Bool
    var usesDemoData: Bool
    var kbPayLinked: Bool

    var monthlyIncome: Int
    var savingsGoal: Int
    var direction: SpendDirection
    var hobbies: [String]

    var calendarDays: [PlanDay]
    var dismissedPredictions: [String]
    var tuneAuditLog: [TuneAuditEntry] = []
    var rejectedAdjustmentIDs: [String] = []
}

extension PersistedState {
    private enum CodingKeys: String, CodingKey {
        case version, hasOnboarded, usesDemoData, kbPayLinked, monthlyIncome,
             savingsGoal, direction, hobbies, calendarDays, learnedSpendRecords, dismissedPredictions,
             dailyCloseDismissed, tuneAuditLog, rejectedAdjustmentIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        hasOnboarded = try c.decodeIfPresent(Bool.self, forKey: .hasOnboarded) ?? false
        usesDemoData = try c.decodeIfPresent(Bool.self, forKey: .usesDemoData) ?? true
        kbPayLinked = try c.decodeIfPresent(Bool.self, forKey: .kbPayLinked) ?? false
        monthlyIncome = try c.decodeIfPresent(Int.self, forKey: .monthlyIncome) ?? 2_200_000
        savingsGoal = try c.decodeIfPresent(Int.self, forKey: .savingsGoal) ?? 800_000
        direction = try c.decodeIfPresent(SpendDirection.self, forKey: .direction) ?? .maintain
        hobbies = try c.decodeIfPresent([String].self, forKey: .hobbies) ?? []
        calendarDays = try c.decodeIfPresent([PlanDay].self, forKey: .calendarDays) ?? []
        // 구버전의 현금 결제 학습값은 읽어서 버린다. 카드 거래만 쓰는 현재 계약에
        // 섞지 않으면서도 나머지 일정·설정은 그대로 복원한다.
        _ = try c.decodeIfPresent([SpendRecord].self, forKey: .learnedSpendRecords)
        dismissedPredictions = try c.decodeIfPresent([String].self, forKey: .dismissedPredictions) ?? []
        _ = try c.decodeIfPresent(Bool.self, forKey: .dailyCloseDismissed)
        tuneAuditLog = try c.decodeIfPresent([TuneAuditEntry].self, forKey: .tuneAuditLog) ?? []
        rejectedAdjustmentIDs = try c.decodeIfPresent([String].self,
                                                       forKey: .rejectedAdjustmentIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(hasOnboarded, forKey: .hasOnboarded)
        try c.encode(usesDemoData, forKey: .usesDemoData)
        try c.encode(kbPayLinked, forKey: .kbPayLinked)
        try c.encode(monthlyIncome, forKey: .monthlyIncome)
        try c.encode(savingsGoal, forKey: .savingsGoal)
        try c.encode(direction, forKey: .direction)
        try c.encode(hobbies, forKey: .hobbies)
        try c.encode(calendarDays, forKey: .calendarDays)
        try c.encode(dismissedPredictions, forKey: .dismissedPredictions)
        try c.encode(tuneAuditLog, forKey: .tuneAuditLog)
        try c.encode(rejectedAdjustmentIDs, forKey: .rejectedAdjustmentIDs)
    }
}

enum LocalStore {

    /// 파일이 있는데 읽지 못한 경우. 이 상태에서는 새 시드로 기존 파일을 덮어쓰지 않는다.
    static private(set) var hasUnreadableState = false

    /// 테스트 중에는 읽지도 쓰지도 않는다.
    ///
    /// 단위 테스트는 시드 데이터를 전제로 기대값을 적어놨다. 저장본을 읽으면
    /// 앞선 실행이 남긴 일정이 섞여 기대값이 깨지고, 반대로 쓰면 시뮬레이터에
    /// 흔적을 남겨 다음 실행이 또 흔들린다. 양쪽 다 막는다.
    static var isDisabled: Bool {
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-ui-test") }) {
            return true
        }
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("state.json")
    }

    static func load() -> PersistedState? {
        guard !isDisabled else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            hasUnreadableState = false
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.version == PersistedState.currentVersion,
              !state.calendarDays.isEmpty else {
            hasUnreadableState = true
            return nil
        }
        // 이전 버전에서 만든 파일도 읽는 순간 백업 제외 상태를 확인한다.
        do {
            try excludeFromBackup()
        } catch {
            // 개인정보 보호 속성을 보장할 수 없으면 영속성보다 보호를 우선한다.
            try? FileManager.default.removeItem(at: url)
            hasUnreadableState = true
            return nil
        }
        hasUnreadableState = false
        return state
    }

    static func save(_ state: PersistedState) {
        guard !isDisabled, !hasUnreadableState,
              let data = try? JSONEncoder().encode(state) else { return }
        // 일정 제목과 소비 금액이 들어 있다. 캡처와 같은 등급을 걸어
        // 기기가 잠긴 동안에는 복호화되지 않게 한다.
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            // Documents는 기본적으로 기기 백업 대상이다. '기기에만 저장'이라는 약속을
            // 실제로 지키려면 파일 보호뿐 아니라 iCloud/iTunes 백업에서도 제외해야 한다.
            try excludeFromBackup()
        } catch {
            // 백업 제외까지 완료되지 않은 사본은 남기지 않는다. 앱은 메모리에서 계속 동작하고
            // 다음 변경 때 다시 저장을 시도한다.
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func excludeFromBackup() throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedURL = url
        try protectedURL.setResourceValues(values)
    }

    /// 시연을 처음부터 다시 할 때. 지우면 다음 실행이 시드 데이터로 시작한다.
    static func clear() {
        try? FileManager.default.removeItem(at: url)
        hasUnreadableState = false
    }
}
