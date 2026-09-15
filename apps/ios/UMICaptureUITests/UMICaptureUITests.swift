import XCTest

final class UMICaptureUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "--umi-capture-docs-language", "english",
            "--umi-capture-docs-source-acknowledged", "false",
            "--umi-capture-docs-tutorial-completed", "false"
        ]
    }

    func testLaunchesAtIndependentSourceNotice() {
        app.launch()

        XCTAssertTrue(
            app.buttons["umi_capture.launch.provenance-continue"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.staticTexts["Software source and attribution"].exists)
        XCTAssertTrue(app.staticTexts["Developer"].exists)
        XCTAssertTrue(app.staticTexts["Inspired by"].exists)
    }

    func testProvenanceContinuesToTutorial() {
        app.launch()
        let continueButton = app.buttons["umi_capture.launch.provenance-continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 8))
        continueButton.tap()

        XCTAssertTrue(app.staticTexts["Quick start"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["umi_capture.launch.tutorial-finish"].exists)
    }
}
