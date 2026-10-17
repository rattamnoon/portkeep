import XCTest

/// Drives the real Settings window against a scratch data folder: add a tunnel, run it, rename it, delete it.
final class SettingsSmokeTests: XCTestCase {
    private var dataDir: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment = ["BURROW_DATA_DIR": dataDir.path, "BURROW_SHOW": "settings", "BURROW_DEBUG": "1"]
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
    }

    override func tearDown() {
        // The app's own record of commands and state changes, for diagnosing a failure.
        if let log = try? String(contentsOf: dataDir.appendingPathComponent("debug.log"), encoding: .utf8) {
            print("BURROW-DEBUG-LOG\n\(log)END-BURROW-DEBUG-LOG")
        }
        app.terminate()
        try? FileManager.default.removeItem(at: dataDir)
    }

    private var savedJSON: String {
        (try? String(contentsOf: dataDir.appendingPathComponent("tunnels.json"), encoding: .utf8)) ?? ""
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openAddSheet() {
        let add = app.buttons["sidebar.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        XCTAssertTrue(app.staticTexts["Custom Command"].firstMatch.waitForExistence(timeout: 5), "Add Tunnel window should open")
    }

    private func replace(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    func testAddRunRenameDelete() throws {
        let port = Int.random(in: 30000...40000)

        // Add a custom-command tunnel.
        openAddSheet()
        app.staticTexts["Custom Command"].firstMatch.click()
        XCTAssertTrue(app.textFields["editor.command"].firstMatch.waitForExistence(timeout: 3))
        replace(app.textFields["editor.name"].firstMatch, with: "Smoke HTTP")
        replace(app.textFields["editor.command"].firstMatch, with: "exec python3 -m http.server {port} --bind 127.0.0.1")
        replace(app.textFields["editor.localPort"].firstMatch, with: String(port))
        let confirm = app.buttons["add.confirm"].firstMatch
        XCTAssertTrue(confirm.isEnabled, "Add Tunnel should enable once required fields are filled")
        confirm.click()

        let row = app.staticTexts["Smoke HTTP"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(savedJSON.contains("Smoke HTTP"))

        // Run it and wait until the port really answers.
        // Closing the Add Tunnel window can leave the app inactive, and an inactive app's controls aren't hittable.
        app.activate()
        row.click()
        // By identifier only: SwiftUI exposes a switch-style Toggle as a checkbox on some macOS versions.
        let toggle = element("detail.toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        let status = element("detail.status")
        let connected = NSPredicate(format: "value BEGINSWITH 'Connected'")
        expectation(for: connected, evaluatedWith: status)
        waitForExpectations(timeout: 20)

        // Rename and save.
        replace(app.textFields["editor.name"].firstMatch, with: "Smoke HTTP 2")
        element("detail.save").click()
        XCTAssertTrue(app.staticTexts["Smoke HTTP 2"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(savedJSON.contains("Smoke HTTP 2"))

        // Delete.
        element("sidebar.remove").click()
        let confirmRemove = element("sidebar.confirmRemove")
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 3))
        confirmRemove.click()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.staticTexts["Smoke HTTP 2"].firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(savedJSON.contains("Smoke HTTP"))
    }

    func testEveryMethodShowsItsFields() throws {
        openAddSheet()
        let expected: [(String, String)] = [
            ("SSH", "Host"), ("AWS SSM", "Instance ID"), ("Kubernetes", "Namespace"),
            ("Google Cloud IAP", "Zone"), ("Cloudflare Access", "Hostname"), ("Custom Command", "Command"),
        ]
        for (method, field) in expected {
            app.staticTexts[method].firstMatch.click()
            XCTAssertTrue(app.staticTexts[field].firstMatch.waitForExistence(timeout: 2) || app.textFields[field].firstMatch.exists,
                          "\(method) should show \(field)")
        }
    }
}
