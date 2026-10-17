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
        app.launchEnvironment = ["BURROW_DATA_DIR": dataDir.path, "BURROW_SHOW": "settings"]
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        try? FileManager.default.removeItem(at: dataDir)
    }

    private var savedJSON: String {
        (try? String(contentsOf: dataDir.appendingPathComponent("tunnels.json"), encoding: .utf8)) ?? ""
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
        row.click()
        app.switches["detail.toggle"].firstMatch.click()
        let status = app.staticTexts["detail.status"].firstMatch
        let connected = NSPredicate(format: "value BEGINSWITH 'Connected'")
        expectation(for: connected, evaluatedWith: status)
        waitForExpectations(timeout: 20)

        // Rename and save.
        replace(app.textFields["editor.name"].firstMatch, with: "Smoke HTTP 2")
        app.buttons["detail.save"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Smoke HTTP 2"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(savedJSON.contains("Smoke HTTP 2"))

        // Delete.
        app.buttons["sidebar.remove"].firstMatch.click()
        let confirmRemove = app.buttons["sidebar.confirmRemove"].firstMatch
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
