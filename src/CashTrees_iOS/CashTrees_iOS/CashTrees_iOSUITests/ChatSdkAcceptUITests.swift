import XCTest

/// Soft QA: open @pwa001 chat, capture inbound, reverse-send text (+ try media).
final class ChatSdkAcceptUITests: XCTestCase {
    private let pwaEoa = "0xa61be17254004182de9e5db4a22abe7ffef36a16"
    private let evidenceDir = "/tmp/chat-sdk-accept"

    @MainActor
    private func dismissPasteIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllow = springboard.buttons["Don’t Allow Paste"]
        let dontAllowAscii = springboard.buttons["Don't Allow Paste"]
        if dontAllow.waitForExistence(timeout: 2) {
            dontAllow.tap()
        } else if dontAllowAscii.waitForExistence(timeout: 1) {
            dontAllowAscii.tap()
        }
    }

    @MainActor
    private func saveShot(_ name: String) throws {
        let shot = XCUIScreen.main.screenshot()
        let dest = URL(fileURLWithPath: "\(evidenceDir)/\(name).png")
        try shot.pngRepresentation.write(to: dest)
        add(XCTAttachment(screenshot: shot))
    }

    @MainActor
    private func openPwa001Chat(_ app: XCUIApplication) {
        let inner = "https://beamio.app/app/#/chat/\(pwaEoa)"
        let encoded = inner.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? inner
        let deeplink = URL(string: "beamio://open?target=\(encoded)")!
        app.open(deeplink)
        Thread.sleep(forTimeInterval: 5.0)
        dismissPasteIfNeeded()
        Thread.sleep(forTimeInterval: 2.0)
    }

    @MainActor
    private func composerField(in app: XCUIApplication) -> XCUIElement? {
        let candidates = [
            app.textFields["iMessage…"],
            app.textFields["iMessage..."],
            app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS[c] %@", "iMessage")).firstMatch,
            app.textViews.matching(NSPredicate(format: "placeholderValue CONTAINS[c] %@", "iMessage")).firstMatch,
            app.textFields.element(boundBy: 0),
            app.textViews.element(boundBy: 0),
        ]
        for el in candidates {
            if el.exists && el.isHittable { return el }
            if el.waitForExistence(timeout: 1) && el.isHittable { return el }
        }
        // WebView often exposes TextField without placeholder via query
        let any = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR placeholderValue CONTAINS[c] %@", "iMessage", "iMessage")
        ).firstMatch
        if any.waitForExistence(timeout: 2) { return any }
        return nil
    }

    @MainActor
    private func tapSend(in app: XCUIApplication) {
        let send = app.buttons["Send"]
        if send.waitForExistence(timeout: 2) && send.isHittable {
            send.tap()
            return
        }
        // Arrow / paper-plane near bottom-right
        let plane = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "send")).firstMatch
        if plane.exists && plane.isHittable {
            plane.tap()
            return
        }
        // Fallback: coordinate near bottom-right of screen
        let frame = app.frame
        let coord = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.93))
        coord.tap()
        _ = frame
    }

    @MainActor
    func testReverseSendTextAndCaptureInbound() throws {
        let app = XCUIApplication(bundleIdentifier: "com.beamio.beamio")
        app.launchArguments = []
        app.launch()
        app.activate()
        dismissPasteIfNeeded()

        openPwa001Chat(app)
        try saveShot("03-ios-chat-inbound-after-open")

        // Reverse text
        guard let field = composerField(in: app) else {
            try saveShot("03b-ios-no-composer")
            XCTFail("composer not found")
            return
        }
        field.tap()
        Thread.sleep(forTimeInterval: 0.5)
        let msg = "ios-reverse-text \(Int(Date().timeIntervalSince1970))"
        field.typeText(msg)
        Thread.sleep(forTimeInterval: 0.4)
        tapSend(in: app)
        Thread.sleep(forTimeInterval: 4.0)
        try saveShot("04-ios-reverse-text-sent")

        // Try open attach (+) for media path evidence (Photos may need manual grant)
        let plus = app.buttons.matching(NSPredicate(format: "label == '+' OR label CONTAINS[c] %@", "attach")).firstMatch
        if plus.waitForExistence(timeout: 2) && plus.isHittable {
            plus.tap()
            Thread.sleep(forTimeInterval: 1.5)
            try saveShot("05-ios-attach-sheet")
            // Prefer Photo Library / Photos / Choose Photo
            let photos = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@", "Photo", "Library", "Gallery")
            ).firstMatch
            if photos.waitForExistence(timeout: 2) && photos.isHittable {
                photos.tap()
                Thread.sleep(forTimeInterval: 2.0)
                try saveShot("06-ios-photos-picker")
                let firstCell = app.cells.element(boundBy: 0)
                if firstCell.waitForExistence(timeout: 3) {
                    firstCell.tap()
                    Thread.sleep(forTimeInterval: 1.0)
                    let add = app.buttons["Add"].exists ? app.buttons["Add"] : app.buttons["Done"]
                    if add.waitForExistence(timeout: 2) { add.tap() }
                    Thread.sleep(forTimeInterval: 2.0)
                    tapSend(in: app)
                    Thread.sleep(forTimeInterval: 5.0)
                    try saveShot("07-ios-reverse-image-attempt")
                }
            }
        }

        Thread.sleep(forTimeInterval: 2.0)
        try saveShot("08-ios-final-chat")
        XCTAssertGreaterThan(XCUIScreen.main.screenshot().pngRepresentation.count, 10_000)
    }
}
