//
//  KB_TuneUITests.swift
//  KB_TuneUITests
//
//  공모전 데모의 핵심 상태를 고정한다. 날짜와 장부 상태를 launch argument로 주입해
//  실행일이나 앞선 테스트 순서에 영향을 받지 않는 스크린샷을 남긴다.
//

import XCTest

final class KB_TuneUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBudgetStatePositiveScreenshot() throws {
        let app = launchMain(state: "positive")

        XCTAssertTrue(app.staticTexts["이번 주 추가 사용 가능액"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["이번 주에 추가로 쓸 수 있어요"].exists)
        XCTAssertTrue(app.buttons["add-event-primary"].exists)
        XCTAssertFalse(app.buttons["show-adjustments"].exists)
        XCTAssertTrue(app.buttons["billing-dock"].exists)

        try capture("budget-positive", in: app)
    }

    @MainActor
    func testBudgetStateZeroScreenshot() throws {
        let app = launchMain(state: "zero")

        XCTAssertTrue(app.staticTexts["이번 주 추가 지출 여유가 없어요"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["show-adjustments"].exists)
        XCTAssertTrue(app.buttons["add-event-primary"].exists)

        try capture("budget-zero", in: app)
    }

    @MainActor
    func testBudgetStateNegativeScreenshot() throws {
        let app = launchMain(state: "negative")

        XCTAssertTrue(app.staticTexts["지난주 초과 사용이 이번 주에 반영됐어요"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["show-adjustments"].exists)
        XCTAssertTrue(app.buttons["add-event-primary"].exists)

        try capture("budget-negative", in: app)
    }

    @MainActor
    func testPrimaryNavigationAndTerminology() throws {
        let app = launchMain(state: "zero")

        for tab in ["주간 탭", "대화 탭", "분석 탭", "카드·적금 탭"] {
            XCTAssertTrue(app.buttons[tab].waitForExistence(timeout: 3))
        }
        XCTAssertTrue(app.staticTexts["이번 주 추가 사용 가능액"].exists)
        XCTAssertTrue(app.staticTexts["다음 결제일 청구액"].exists)
        XCTAssertFalse(app.staticTexts["8월 14일 카드 청구액"].exists)

        app.buttons["분석 탭"].tap()
        XCTAssertTrue(app.staticTexts["7월 지출"].waitForExistence(timeout: 3))
        app.buttons["대화 탭"].tap()
        XCTAssertTrue(app.staticTexts["Tune"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testChatFeelsConversationalAndOffersAnAction() throws {
        let app = launchMain(state: "zero")
        app.buttons["대화 탭"].tap()

        XCTAssertTrue(app.staticTexts["Tune"].waitForExistence(timeout: 3))
        let field = app.textFields["편하게 말해 주세요"]
        field.tap()
        field.typeText("안녕")
        app.buttons["질문 보내기"].tap()
        XCTAssertTrue(app.staticTexts["안녕하세요, 성제님. 오늘은 어떤 소비가 마음에 걸려요?"]
            .waitForExistence(timeout: 5))
        try capture("chat-natural-reply", in: app)

        field.tap()
        field.typeText("일정 하나 미뤄줘")
        app.buttons["질문 보내기"].tap()
        let moveButton = app.buttons["다음 주로 옮기기"]
        XCTAssertTrue(moveButton.waitForExistence(timeout: 5))
        // 답변이 붙은 직후 0.25초 동안 맨 아래로 스크롤된다. 존재 여부를 확인한
        // 같은 프레임에서 isHittable을 읽으면 아직 화면 밖이라 간헐적으로 실패한다.
        XCTAssertTrue(waitUntilHittable(moveButton))
        try capture("chat-move-action", in: app)
    }

    // MARK: 기존 회귀 — 화면 이동·계산 근거·챗봇 답변이 살아 있는지

    /// 주간 화면의 금액 근거. 히어로 숫자와 계산 기준 시트가 같은 값을 말해야 한다.
    @MainActor
    func testWeeklyPlanCalculationBasis() throws {
        let app = launchMain()

        XCTAssertTrue(app.staticTexts["성제님의 이번 주 예상 지출은 95,000원"].waitForExistence(timeout: 5))

        app.buttons["계산 기준 보기"].tap()
        XCTAssertTrue(app.staticTexts["0원 계산 기준"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["할부로 다음 달에 넘어갈 돈"].exists)
        XCTAssertTrue(app.staticTexts["90,590원"].exists)
    }

    /// 월↔주 전환과 설정의 소비 방향 메뉴 — 탭 밖으로 나가는 두 경로.
    @MainActor
    func testPlanModeSwitchAndSettingsDirectionMenu() throws {
        let app = launchMain()

        app.buttons["plan-mode-month"].tap()
        XCTAssertTrue(app.staticTexts["2026년 7월"].waitForExistence(timeout: 3))
        // 기본 캘린더 801,000원에 데모에서 새로 잡은 일정 두 건(52,000원·28,000원)이
        // 포함된 값이다. 월간 합계는 캘린더 원본에서 파생되어야 한다.
        XCTAssertTrue(app.staticTexts["881,000원"].waitForExistence(timeout: 3))

        app.buttons["plan-mode-week"].tap()
        XCTAssertTrue(app.buttons["계산 기준 보기"].waitForExistence(timeout: 3))

        app.buttons["내 계획과 설정"].tap()
        XCTAssertTrue(app.staticTexts["설정"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["이번 달 소비 방향"].waitForExistence(timeout: 3))
        app.buttons["유지"].tap()
        XCTAssertTrue(app.buttons["줄이기"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["늘리기"].exists)
    }

    /// 이번 주 금액을 현재 결정론 장부와 같은 값으로 답하는지.
    @MainActor
    func testChatAnswersWeeklyAmountFromCurrentLedger() throws {
        let app = launchMain()
        app.buttons["대화 탭"].tap()

        let field = app.textFields["편하게 말해 주세요"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("이번 주 얼마까지 써도 돼?")
        app.buttons["질문 보내기"].tap()

        XCTAssertTrue(app.staticTexts["이번 주에는 0원을 더 써도 돼요."]
            .waitForExistence(timeout: 6))
    }

    /// 개인정보를 외부에 보내지 않는 기본 모드에서도 자연어 일정 분석과
    /// 과거 카페 소비 기반 금액 추정이 온디바이스로 끝까지 동작해야 한다.
    @MainActor
    func testPrivateOnDeviceCafeEventProposalScreenshot() throws {
        let app = launchMain()
        app.buttons["대화 탭"].tap()

        let privateBadge = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "기기 안에서만"))
            .firstMatch
        XCTAssertTrue(privateBadge.waitForExistence(timeout: 3))

        let field = app.textFields["편하게 말해 주세요"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("8월 5일 카페 갈래")
        app.buttons["질문 보내기"].tap()

        XCTAssertTrue(app.staticTexts["카페 약속"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["8월 5일"].exists)
        XCTAssertTrue(app.staticTexts["20,000원"].exists)
        let addButton = app.buttons["일정 추가"]
        XCTAssertTrue(addButton.exists)
        XCTAssertTrue(waitUntilHittable(addButton))

        try capture("chat-private-cafe-proposal", in: app)
    }

    /// 금액이 안 적힌 캘린더 일정을 얼마로 잡았는지 설명하는지.
    @MainActor
    func testChatExplainsAmbiguousCalendarCost() throws {
        let app = launchMain()
        app.buttons["대화 탭"].tap()

        let field = app.textFields["편하게 말해 주세요"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("레이저 제모 비용 알려줘")
        app.buttons["질문 보내기"].tap()

        XCTAssertTrue(app.staticTexts["레이저 제모는 50,000원으로 잡았어요."]
            .waitForExistence(timeout: 6))
    }

    /// 주간 화면의 조정안과 챗봇의 미루기 제안은 같은 일정을 가리켜야 한다.
    @MainActor
    func testAdjustmentAndChatAgreeOnTheSameEvent() throws {
        let app = launchMain(state: "zero")

        app.buttons["show-adjustments"].tap()
        let applyButton = app.buttons["apply-adjustment"]
        XCTAssertTrue(applyButton.waitForExistence(timeout: 3))
        let planAmount = applyButton.label

        app.buttons["대화 탭"].tap()
        let field = app.textFields["편하게 말해 주세요"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("일정 하나 미뤄줘")
        app.buttons["질문 보내기"].tap()

        let moveButton = app.buttons["다음 주로 옮기기"]
        XCTAssertTrue(moveButton.waitForExistence(timeout: 5))
        // 조정안 버튼은 "다음 주로 이동 +52,000원"처럼 금액을 달고 있다.
        // 챗봇 답변의 근거 문장에도 같은 금액이 있어야 두 화면이 같은 일정을 말하는 것이다.
        let amount = planAmount.components(separatedBy: "+").last ?? ""
        XCTAssertFalse(amount.isEmpty)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", amount))
            .firstMatch.exists)
    }

    /// 문서·발표용 화면을 한 번에 모아 찍는다.
    ///
    /// 기기 안에서만 모드(`-ui-test-offline`)로 돌아서 네트워크 없이 재현된다.
    /// 실패해도 나머지 화면은 계속 찍도록 각 단계를 독립적으로 둔다 —
    /// 화면 하나가 바뀌었다고 전체 캡처가 날아가면 쓸모가 없다.
    @MainActor
    func testCaptureAllScreens() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KB_TUNE_CAPTURE_ALL"] == "1",
            "문서용 전체 캡처 전용 — KB_TUNE_CAPTURE_ALL=1 로 실행"
        )
        continueAfterFailure = true
        let app = launchMain(state: "zero")
        XCTAssertTrue(app.staticTexts["이번 주 추가 사용 가능액"].waitForExistence(timeout: 8))

        // ── 주간
        try capture("01-weekly", in: app)

        // 조정안 펼친 상태 — 예산이 0원일 때 무엇을 옮기라고 하는지
        if app.buttons["show-adjustments"].exists {
            app.buttons["show-adjustments"].tap()
            _ = app.buttons["apply-adjustment"].waitForExistence(timeout: 3)
            try capture("02-weekly-adjustment", in: app)
        }

        // 월간
        if app.buttons["plan-mode-month"].exists {
            app.buttons["plan-mode-month"].tap()
            _ = app.staticTexts["2026년 7월"].waitForExistence(timeout: 3)
            try capture("03-month", in: app)
            app.buttons["plan-mode-week"].tap()
            _ = app.buttons["plan-mode-month"].waitForExistence(timeout: 3)
        }

        // 청구 상세
        if app.buttons["billing-dock"].exists {
            app.buttons["billing-dock"].tap()
            Thread.sleep(forTimeInterval: 1.5)
            try capture("04-billing", in: app)
            dismissSheet(app)
        }

        // 일정 추가
        if app.buttons["add-event-primary"].exists {
            app.buttons["add-event-primary"].tap()
            Thread.sleep(forTimeInterval: 1.5)
            try capture("05-add-event", in: app)
            dismissSheet(app)
        }

        // ── 대화
        app.buttons["대화 탭"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        try capture("06-chat", in: app)

        let field = app.textFields["편하게 말해 주세요"]
        if field.waitForExistence(timeout: 3) {
            field.tap()
            field.typeText("8월 5일 카페 갈래")
            app.buttons["질문 보내기"].tap()
            _ = app.staticTexts["카페 약속"].waitForExistence(timeout: 8)
            Thread.sleep(forTimeInterval: 1)
            try capture("07-chat-event-proposal", in: app)
        }

        // ── 분석
        app.buttons["분석 탭"].tap()
        Thread.sleep(forTimeInterval: 1.5)
        try capture("08-analysis", in: app)

        // ── 카드·적금
        app.buttons["카드·적금 탭"].tap()
        Thread.sleep(forTimeInterval: 2)
        try capture("09-products-card", in: app)

        // 적금 쪽 세그먼트가 있으면 그것도
        let savings = app.buttons["적금"]
        if savings.waitForExistence(timeout: 3) {
            savings.tap()
            Thread.sleep(forTimeInterval: 1.5)
            try capture("10-products-savings", in: app)
        }

        // ── 설정
        app.buttons["주간 탭"].tap()
        Thread.sleep(forTimeInterval: 1)
        let settings = app.buttons["설정"]
        if settings.waitForExistence(timeout: 3) {
            settings.tap()
            Thread.sleep(forTimeInterval: 1.5)
            try capture("11-settings", in: app)
            dismissSheet(app)
        }
    }

    /// 온보딩은 첫 실행에서만 보이므로 따로 띄운다.
    @MainActor
    func testCaptureOnboarding() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KB_TUNE_CAPTURE_ALL"] == "1",
            "문서용 전체 캡처 전용 — KB_TUNE_CAPTURE_ALL=1 로 실행"
        )
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-offline", "-ui-test-date-22"]
        app.launch()
        Thread.sleep(forTimeInterval: 4)   // 스플래시
        try capture("00-onboarding", in: app)
    }

    @MainActor
    private func dismissSheet(_ app: XCUIApplication) {
        for label in ["닫기", "취소"] where app.buttons[label].exists {
            app.buttons[label].tap()
            Thread.sleep(forTimeInterval: 1)
            return
        }
        app.swipeDown(velocity: .fast)
        Thread.sleep(forTimeInterval: 1)
    }

    /// 실제 백엔드에 붙여 대화 말투와 지난 소비 열람을 캡처한다(문서용).
    ///
    /// 기본 묶음은 네트워크에 기대면 안 되므로 `KB_TUNE_LIVE_CHAT=1` 일 때만 돈다.
    /// 백엔드를 띄우고 나서 실행할 것 — `cd backend && ./run.sh`.
    @MainActor
    func testLiveChatAnswersPastSpendingScreenshot() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KB_TUNE_LIVE_CHAT"] == "1",
            "실서버 캡처 전용 — KB_TUNE_LIVE_CHAT=1 로 실행"
        )
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-main", "-ui-test-date-22"]
        app.launch()
        app.buttons["대화 탭"].tap()

        // 외부 AI는 명시적으로 고른 뒤에만 쓴다. 캡처도 같은 경로를 통과한다.
        // 앱을 지우고 시작하므로 시트는 반드시 떠야 한다 — 안 뜨면 기기 안에서만으로
        // 답하게 되고, 그러면 이 캡처는 목적을 잃는다.
        let consent = app.buttons["식별정보 없이 분석"]
        XCTAssertTrue(consent.waitForExistence(timeout: 6), "동의 시트가 뜨지 않았다")
        consent.tap()

        // 배지가 바뀌어야 외부 AI 경로가 실제로 켜진 것이다.
        let cloudBadge = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "직접식별자·원문 비공개"))
            .firstMatch
        XCTAssertTrue(cloudBadge.waitForExistence(timeout: 5), "외부 AI 경로가 켜지지 않았다")

        let field = app.textFields["편하게 말해 주세요"]
        XCTAssertTrue(field.waitForExistence(timeout: 4))
        field.tap()
        field.typeText("이번 달 카페에 얼마 썼어?")
        app.buttons["질문 보내기"].tap()

        // 스크립트 폴백("이번 주에는 N원을 더 써도 돼요")이 아니라
        // 카페를 짚어 답했는지 본다. 느슨하게 두면 폴백이 통과해 버린다.
        let cafeAnswer = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "카페")
        ).element(boundBy: 0)
        XCTAssertTrue(cafeAnswer.waitForExistence(timeout: 40), "카페 지출을 짚은 답이 오지 않았다")
        Thread.sleep(forTimeInterval: 2)

        try capture("chat-past-spending", in: app)
    }

    @MainActor
    private func launchMain(state: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-ui-test-main", "-ui-test-offline", "-ui-test-date-22"]
        if let state { arguments.append("-ui-test-budget-\(state)") }
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let directory = ProcessInfo.processInfo.environment["KB_TUNE_SCREENSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("\(name).png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try screenshot.pngRepresentation.write(to: url, options: .atomic)
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement,
                                   timeout: TimeInterval = 3) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
