import XCTest

/// Exercises NativeWorkbenchExperimentView in CI, which nothing previously
/// did — the "Experimental: Native Workbench…" menu item deliberately has
/// no keyboard shortcut (see iPadVSCodeApp.swift), so OpenFolderFlowUITests'
/// Cmd+O approach doesn't generalize here, and driving iPad's real menu bar
/// from XCUITest is its own unreliable can of worms. Instead this launches
/// with `-UITestOpenNativeWorkbench`, a CI-only hook ContentView.swift reads
/// to open the same fullScreenCover the menu item does.
///
/// This test has no real pass/fail assertion about the native workbench
/// itself working — it isn't expected to (see NativeWorkbenchExperimentView's
/// own doc comment: only 1 of ~31 real vscode IPC channels exists on the
/// backend so far). Its entire job is to give the view real time to load
/// and fail in whatever way it actually fails, so
/// simulator-test.yml's log capture (which now also picks up
/// NativeConsoleForwarder's console/uncaught-error forwarding) has
/// something real to show instead of the view never having been opened at
/// all in this pipeline.
final class NativeWorkbenchUITests: XCTestCase {
    func testOpenNativeWorkbenchExperimentAndObserve() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestOpenNativeWorkbench"]
        app.launch()

        // Long enough for code-server's own startup (ContentView still
        // starts it unconditionally, even though this test doesn't use it)
        // plus real time for the vscode-desktop bundle to fetch over the
        // vscode-file:// scheme handler, evaluate, and either render or
        // fail — see NativeWorkbenchExperimentView.setUpIfNeeded().
        Thread.sleep(forTimeInterval: 40)

        print("=== ACCESSIBILITY TREE AFTER OPENING NATIVE WORKBENCH EXPERIMENT ===")
        print(app.debugDescription)
        print("=== END ACCESSIBILITY TREE ===")
    }
}
