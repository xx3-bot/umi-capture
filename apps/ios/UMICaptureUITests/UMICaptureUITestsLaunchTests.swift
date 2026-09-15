import XCTest

final class UMICaptureUITestsLaunchTests: XCTestCase {
    func testStaticProvenanceScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "--umi-capture-docs-language", "english",
            "--umi-capture-docs-source-acknowledged", "false",
            "--umi-capture-docs-tutorial-completed", "false"
        ]
        app.launch()

        XCTAssertTrue(
            app.buttons["umi_capture.launch.provenance-continue"]
                .waitForExistence(timeout: 8)
        )
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "umi_capture-ios-source-notice-static-ui"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
