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

        // Give the system sheet time to animate in before inspecting.
        Thread.sleep(forTimeInterval: 2)

        // Printed to the plain-text xcodebuild log (not just the binary
        // .xcresult, which isn't inspectable outside macOS) so a failure
        // here says exactly what's actually on screen instead of requiring
        // a guess at which system element to assert on.
        print("=== ACCESSIBILITY TREE AFTER TAPPING OPEN FOLDER ===")
        print(app.debugDescription)
        print("=== END ACCESSIBILITY TREE ===")

        let pickerAppeared = app.buttons["Cancel"].exists
            || app.navigationBars.buttons["Cancel"].exists
            || app.otherElements["DOCMenuButtonCancel"].exists
        XCTAssertTrue(pickerAppeared, "expected some form of document picker/cancel affordance to appear after tapping Open Folder… — see the accessibility tree dump above in the test log for what actually rendered")
    }
}
