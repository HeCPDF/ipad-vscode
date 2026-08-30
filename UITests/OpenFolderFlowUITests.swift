import XCTest

/// Runs in CI against the iOS Simulator (see .github/workflows/build.yml).
/// Confirms the one UI flow that doesn't depend on either
/// NEPacketTunnelProvider extension actually working — Simulator's
/// Network Extension support gaps don't affect this test.
final class OpenFolderFlowUITests: XCTestCase {
    func testOpenFolderButtonPresentsPicker() {
        let app = XCUIApplication()
        app.launch()

        let openFolderButton = app.buttons["Open Folder…"]
        XCTAssertTrue(openFolderButton.waitForExistence(timeout: 10), "Open Folder button should appear on first launch")
        openFolderButton.tap()

        // UIDocumentPickerViewController is a system sheet; checking that
        // *our* prompt got covered is unreliable (a background view
        // controller can still report as accessibility-"existing" under a
        // modal sheet even though it's not visible). Instead, check for a
        // system element the picker itself is guaranteed to present: its
        // Cancel button.
        attachScreenshot(app, name: "after-tap-open-folder")
        let pickerCancelButton = app.buttons["Cancel"]
        XCTAssertTrue(pickerCancelButton.waitForExistence(timeout: 5), "the document picker's Cancel button should appear after tapping Open Folder…")
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
