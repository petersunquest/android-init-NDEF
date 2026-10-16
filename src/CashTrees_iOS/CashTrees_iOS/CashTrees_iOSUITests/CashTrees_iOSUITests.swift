//
//  CashTrees_iOSUITests.swift
//  CashTrees_iOSUITests
//
//  Created by peter on 2026-03-27.
//

import XCTest

final class CashTrees_iOSUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
    }

    /// Soft-seed CallKit Incoming, Accept on SpringBoard, capture full InCall chrome.
    @MainActor
    func testDebugIncomingCallKit() throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let app = XCUIApplication()
        app.launch()
        app.activate()

        let url = URL(string: "beamio://debug-incoming")!
        app.open(url)
        Thread.sleep(forTimeInterval: 2.0)

        // Prefer SpringBoard Accept (banner or full Incoming). Fall back to Answer.
        let acceptLabels = ["Accept", "Answer", "接听"]
        var tapped = false
        for label in acceptLabels {
            let btn = springboard.buttons[label]
            if btn.waitForExistence(timeout: 4.0) {
                btn.tap()
                tapped = true
                break
            }
        }
        if !tapped {
            // Banner may expose the control as a different element type.
            for label in acceptLabels {
                let other = springboard.otherElements[label]
                if other.waitForExistence(timeout: 1.5) {
                    other.tap()
                    tapped = true
                    break
                }
            }
        }
        XCTAssertTrue(tapped, "CallKit Accept/Answer not found on SpringBoard")

        Thread.sleep(forTimeInterval: 2.5)

        // If still only a green status bar, tap top center to expand InCall.
        let coord = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
        coord.tap()
        Thread.sleep(forTimeInterval: 1.5)
        coord.tap()
        Thread.sleep(forTimeInterval: 1.5)

        let shot = XCUIScreen.main.screenshot()
        let dest = URL(fileURLWithPath: "/tmp/ios-accept/uitest-incall.png")
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try shot.pngRepresentation.write(to: dest)
        add(XCTAttachment(screenshot: shot))
        XCTAssertGreaterThan(shot.pngRepresentation.count, 20_000)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
