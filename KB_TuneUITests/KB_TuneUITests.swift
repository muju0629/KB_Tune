//
//  KB_TuneUITests.swift
//  KB_TuneUITests
//
//  Created by Sungjeh Yoon on 7/21/26.
//

import XCTest

final class KB_TuneUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testWeeklyPlanPrimaryJourney() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-main", "-ui-test-offline"]
        app.launch()

        // 계획 화면 히어로는 기준일과 이름을 한 줄로 붙여 그린다.
        XCTAssertTrue(app.staticTexts["2026년 7월 22일 수요일 · 성제님"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["이번 주 일정비는 95,000원이에요."].exists)

        app.buttons["계산 기준 보기"].tap()
        XCTAssertTrue(app.staticTexts["약 60,000원 계산 기준"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["62,000원"].exists)
    }

    @MainActor
    func testPrimaryNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-main", "-ui-test-offline"]
        app.launch()

        for tab in ["주간", "대화", "분석"] {
            XCTAssertTrue(app.tabBars.buttons[tab].waitForExistence(timeout: 3))
        }
        XCTAssertFalse(app.tabBars.buttons["월간"].exists)
        XCTAssertFalse(app.tabBars.buttons["상품"].exists)

        app.buttons["plan-mode-month"].tap()
        XCTAssertTrue(app.staticTexts["2026년 7월"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["801,000원"].exists)
        app.buttons["plan-mode-week"].tap()
        XCTAssertTrue(app.buttons["계산 기준 보기"].waitForExistence(timeout: 3))

        let directionButton = app.buttons["이번 달 소비 방향"]
        XCTAssertTrue(directionButton.exists)
        directionButton.tap()
        XCTAssertTrue(app.staticTexts["이번 달 소비 방향"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testChatThinkingAndPlanUpdateJourney() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-main", "-ui-test-offline"]
        app.launch()

        app.tabBars.buttons["대화"].tap()
        XCTAssertTrue(app.staticTexts["성제님, 이번 주 예산부터 볼까요?"].waitForExistence(timeout: 3))

        app.buttons["이번 주 얼마까지 써도 돼?"].tap()
        XCTAssertTrue(app.staticTexts["chat-thinking"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["이번 주에는 약 60,000원을 더 써도 돼요."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["이번 주 일정비 95,000원 예상"].exists)

        app.buttons["출근비 얼마나 잡았어?"].tap()
        XCTAssertTrue(app.staticTexts["출근 비용은 따로 잡지 않았어요."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testChatExplainsAmbiguousCalendarCost() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-main", "-ui-test-offline"]
        app.launch()

        app.tabBars.buttons["대화"].tap()
        app.textFields.firstMatch.tap()
        app.textFields.firstMatch.typeText("레이저 제모 비용 알려줘")
        app.buttons["질문 보내기"].tap()

        XCTAssertTrue(app.staticTexts["레이저 제모는 50,000원으로 잡았어요."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["이번 주 일정비 95,000원"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
