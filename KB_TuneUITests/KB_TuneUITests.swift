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
        XCTAssertTrue(moveButton.isHittable)
        try capture("chat-move-action", in: app)
    }

    // MARK: 기존 회귀 — 화면 이동·계산 근거·챗봇 답변이 살아 있는지

    /// 주간 화면의 금액 근거. 히어로 숫자와 계산 기준 시트가 같은 값을 말해야 한다.
    @MainActor
    func testWeeklyPlanCalculationBasis() throws {
        let app = launchMain()

        XCTAssertTrue(app.staticTexts["성제님의 이번 주 예상 지출은 95,000원"].waitForExistence(timeout: 5))

        app.buttons["계산 기준 보기"].tap()
        XCTAssertTrue(app.staticTexts["약 60,000원 계산 기준"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["62,000원"].exists)
    }

    /// 월↔주 전환과 소비 방향 시트 — 탭 밖으로 나가는 두 경로.
    @MainActor
    func testPlanModeSwitchAndDirectionSheet() throws {
        let app = launchMain()

        app.buttons["plan-mode-month"].tap()
        XCTAssertTrue(app.staticTexts["2026년 7월"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["801,000원"].exists)

        app.buttons["plan-mode-week"].tap()
        XCTAssertTrue(app.buttons["계산 기준 보기"].waitForExistence(timeout: 3))

        let directionButton = app.buttons["이번 달 소비 방향"]
        XCTAssertTrue(directionButton.exists)
        directionButton.tap()
        XCTAssertTrue(app.staticTexts["이번 달 소비 방향"].waitForExistence(timeout: 3))
    }

    /// 생각 중 표시가 뜨고, 이번 주 금액을 화면과 같은 값으로 답하는지.
    @MainActor
    func testChatShowsThinkingAndAnswersWeeklyAmount() throws {
        let app = launchMain()
        app.buttons["대화 탭"].tap()

        let field = app.textFields["편하게 말해 주세요"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("이번 주 얼마까지 써도 돼?")
        app.buttons["질문 보내기"].tap()

        XCTAssertTrue(app.staticTexts["chat-thinking"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["이번 주에는 약 60,000원을 더 써도 돼요."]
            .waitForExistence(timeout: 6))
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
}
