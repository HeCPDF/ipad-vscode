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

        // UIDocumentPickerViewController is a system sheet; its exact
        // accessibility hierarchy belongs to Apple, not us, so this only
        // checks that *our* prompt got covered by something — not that the
        // picker's internals look a particular way.
        let promptStillFrontmost = app.staticTexts["Open a folder to start editing"].waitForExistence(timeout: 2)
        XCTAssertFalse(promptStillFrontmost, "the open-folder prompt should be covered by the picker sheet after tapping Open Folder…")
    }
}
