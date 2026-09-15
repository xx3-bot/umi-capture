import XCTest

final class DocumentationScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        addUIInterruptionMonitor(
            withDescription: "System permission prompts"
        ) { alert in
            for label in ["Allow", "允许", "OK", "好"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
    }

    func testEnglishDocumentationScreens() {
        captureDocumentationSet(
            language: "english",
            appleLanguages: "(en)",
            appleLocale: "en_US",
            suffix: "en",
            sourceTitle: "Software source and attribution",
            tutorialTitle: "Quick start"
        )
    }

    func testChineseDocumentationScreens() {
        captureDocumentationSet(
            language: "simplifiedChinese",
            appleLanguages: "(zh-Hans)",
            appleLocale: "zh_CN",
            suffix: "zh",
            sourceTitle: "软件来源与署名",
            tutorialTitle: "快速上手"
        )
    }

    func testEnglishAboutDocumentationScreen() {
        captureAboutScreen(
            language: "english",
            appleLanguages: "(en)",
            appleLocale: "en_US",
            suffix: "en"
        )
    }

    func testChineseAboutDocumentationScreen() {
        captureAboutScreen(
            language: "simplifiedChinese",
            appleLanguages: "(zh-Hans)",
            appleLocale: "zh_CN",
            suffix: "zh"
        )
    }

    private func captureDocumentationSet(
        language: String,
        appleLanguages: String,
        appleLocale: String,
        suffix: String,
        sourceTitle: String,
        tutorialTitle: String
    ) {
        launch(
            language: language,
            appleLanguages: appleLanguages,
            appleLocale: appleLocale,
            sourceAcknowledged: false,
            tutorialCompleted: false
        )

        let provenanceContinue = element(
            "umi_capture.launch.provenance-continue"
        )
        XCTAssertTrue(provenanceContinue.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[sourceTitle].exists)
        attachScreenshot(named: "ios-source-\(suffix)")

        provenanceContinue.tap()
        let tutorialFinish = element("umi_capture.launch.tutorial-finish")
        XCTAssertTrue(
            app.staticTexts[tutorialTitle].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.images["move.3d"].exists)
        attachScreenshot(named: "ios-quick-start-\(suffix)")

        let tutorialScrollView = app.scrollViews.firstMatch
        XCTAssertTrue(tutorialScrollView.waitForExistence(timeout: 3))
        tutorialScrollView.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot(named: "ios-tutorial-steps-4-6-\(suffix)")

        reveal(tutorialFinish, direction: .up)
        XCTAssertTrue(tutorialFinish.isHittable)
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot(named: "ios-tutorial-steps-6-7-\(suffix)")
        tutorialFinish.tap()

        waitForHomeAndHandlePermissions()
        attachScreenshot(named: "ios-capture-home-\(suffix)")

        let drawerButton = element("umi_capture.capture.drawer-button")
        XCTAssertTrue(drawerButton.waitForExistence(timeout: 5))
        drawerButton.tap()

        let drawer = element("umi_capture.capture.drawer")
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        XCTAssertTrue(element("umi_capture.capture.language-picker").exists)
        attachScreenshot(named: "ios-drawer-\(suffix)")

        let roleSetup = element("umi_capture.capture.role-setup")
        XCTAssertTrue(roleSetup.waitForExistence(timeout: 3))
        let egoButton = app.buttons["Ego"].firstMatch
        if egoButton.exists && egoButton.isHittable {
            egoButton.tap()
        }
        attachScreenshot(named: "ios-role-setup-\(suffix)")

        let receiverSettings = element(
            "umi_capture.capture.receiver-settings"
        )
        reveal(receiverSettings, direction: .up)
        XCTAssertTrue(receiverSettings.isHittable)
        attachScreenshot(named: "ios-receiver-settings-\(suffix)")

        let recentButton = element(
            "umi_capture.capture.recent-captures-button"
        )
        reveal(recentButton, direction: .down)
        XCTAssertTrue(recentButton.isHittable)
        recentButton.tap()
        let recentCaptures = element("umi_capture.capture.recent-captures")
        XCTAssertTrue(recentCaptures.waitForExistence(timeout: 5))
        expandPresentedSheet()
        attachScreenshot(named: "ios-recent-captures-\(suffix)")
    }

    private func captureAboutScreen(
        language: String,
        appleLanguages: String,
        appleLocale: String,
        suffix: String
    ) {
        launch(
            language: language,
            appleLanguages: appleLanguages,
            appleLocale: appleLocale,
            sourceAcknowledged: true,
            tutorialCompleted: true
        )
        waitForHomeAndHandlePermissions()
        let drawerButton = element("umi_capture.capture.drawer-button")
        XCTAssertTrue(drawerButton.waitForExistence(timeout: 5))
        drawerButton.tap()
        XCTAssertTrue(
            element("umi_capture.capture.drawer").waitForExistence(timeout: 5)
        )
        let aboutButton = element("umi_capture.capture.about-button")
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 3))
        for _ in 0..<10 {
            scrollView.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(aboutButton.isHittable)
        aboutButton.tap()
        XCTAssertTrue(
            element("umi_capture.capture.about").waitForExistence(timeout: 5)
        )
        attachScreenshot(named: "ios-about-\(suffix)")
    }

    private func launch(
        language: String,
        appleLanguages: String,
        appleLocale: String,
        sourceAcknowledged: Bool,
        tutorialCompleted: Bool
    ) {
        app.launchArguments = [
            "-AppleLanguages", appleLanguages,
            "-AppleLocale", appleLocale,
            "--umi-capture-docs-language", language,
            "--umi-capture-docs-source-acknowledged",
            sourceAcknowledged ? "true" : "false",
            "--umi-capture-docs-tutorial-completed",
            tutorialCompleted ? "true" : "false",
        ]
        app.launch()
    }

    private func waitForHomeAndHandlePermissions() {
        let home = element("umi_capture.capture.home")
        for _ in 0..<4 {
            if home.waitForExistence(timeout: 2) {
                app.tap()
                if home.waitForExistence(timeout: 1) {
                    return
                }
            } else {
                app.tap()
            }
        }
        XCTAssertTrue(home.exists)
    }

    private enum SwipeDirection {
        case up
        case down
    }

    private func reveal(
        _ target: XCUIElement,
        direction: SwipeDirection
    ) {
        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.waitForExistence(timeout: 3))
        for _ in 0..<12 {
            if target.exists && target.isHittable {
                return
            }
            switch direction {
            case .up:
                scrollView.swipeUp(velocity: .fast)
            case .down:
                scrollView.swipeDown(velocity: .fast)
            }
        }
    }

    private func expandPresentedSheet() {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func attachScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
