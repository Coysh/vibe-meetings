import XCTest
@testable import VMCore

final class MeetingAppCatalogTests: XCTestCase {
    func testDedicatedCallApps() {
        XCTAssertEqual(MeetingAppCatalog.classify(bundleID: "com.microsoft.teams2")?.id, "teams")
        XCTAssertEqual(MeetingAppCatalog.classify(bundleID: "com.microsoft.teams")?.id, "teams")
        XCTAssertEqual(MeetingAppCatalog.classify(bundleID: "us.zoom.xos")?.id, "zoom")
        XCTAssertEqual(MeetingAppCatalog.classify(bundleID: "com.tinyspeck.slackmacgap.helper")?.id, "slack")
        XCTAssertEqual(MeetingAppCatalog.classify(bundleID: "us.zoom.xos")?.kind, .call)
    }

    func testBrowserHelpersMapToParentBrowser() {
        let chrome = MeetingAppCatalog.classify(bundleID: "com.google.Chrome.helper")
        XCTAssertEqual(chrome?.id, "chrome")
        XCTAssertEqual(chrome?.kind, .browser)
        XCTAssertEqual(MeetingAppCatalog.classify(bundleID: "com.apple.WebKit.GPU")?.id, "safari")
        XCTAssertEqual(MeetingAppCatalog.classify(bundleID: "org.mozilla.plugincontainer")?.id, "firefox")
    }

    func testCaseInsensitive() {
        XCTAssertEqual(MeetingAppCatalog.classify(bundleID: "COM.GOOGLE.CHROME")?.id, "chrome")
    }

    func testSystemServicesIgnored() {
        XCTAssertEqual(MeetingAppCatalog.classify(bundleID: "com.apple.corespeechd")?.kind, .ignored)
        XCTAssertEqual(MeetingAppCatalog.classify(bundleID: "com.apple.VoiceMemos")?.kind, .ignored)
        XCTAssertEqual(MeetingAppCatalog.classify(bundleID: nil, processName: "corespeechd")?.kind, .ignored)
    }

    func testFaceTimeViaDaemonProcessName() {
        XCTAssertEqual(MeetingAppCatalog.classify(bundleID: nil, processName: "avconferenced")?.id, "facetime")
        XCTAssertEqual(MeetingAppCatalog.classify(bundleID: "com.apple.FaceTime")?.kind, .call)
    }

    func testUnknownAppReturnsNil() {
        XCTAssertNil(MeetingAppCatalog.classify(bundleID: "com.example.recorder"))
        XCTAssertNil(MeetingAppCatalog.classify(bundleID: nil, processName: nil))
    }

    func testRunningCallAppSkipsBrowsers() {
        let running: [(bundleID: String?, name: String?)] = [
            ("com.google.Chrome", "Google Chrome"),
            ("com.microsoft.teams2", "Microsoft Teams"),
        ]
        XCTAssertEqual(MeetingAppCatalog.runningCallApp(in: running)?.id, "teams")
        XCTAssertNil(MeetingAppCatalog.runningCallApp(in: [("com.google.Chrome", "Google Chrome")]))
    }
}

final class ReminderScheduleTests: XCTestCase {
    func testEscalatingOffsets() {
        let s = ReminderSchedule.escalating
        XCTAssertEqual((0..<6).compactMap { s.offset(forAttempt: $0) }, [0, 120, 300, 600, 900, 1200])
        XCTAssertEqual(s.gap(afterAttempt: 0), 120)
        XCTAssertEqual(s.gap(afterAttempt: 1), 180)
        XCTAssertEqual(s.gap(afterAttempt: 5), 300)
    }

    func testOnceStopsAfterFirst() {
        XCTAssertEqual(ReminderSchedule.once.offset(forAttempt: 0), 0)
        XCTAssertNil(ReminderSchedule.once.offset(forAttempt: 1))
        XCTAssertNil(ReminderSchedule.once.gap(afterAttempt: 0))
    }
}

final class MeetingPlatformDecodingTests: XCTestCase {
    private struct Box: Codable { var platform: MeetingPlatform? }

    private func decode(_ json: String) throws -> MeetingPlatform? {
        try JSONDecoder().decode(Box.self, from: Data(json.utf8)).platform
    }

    func testDecodesExistingValues() throws {
        XCTAssertEqual(try decode(#"{"platform":"teams"}"#), .teams)
        XCTAssertEqual(try decode(#"{"platform":"other"}"#), .other)
        XCTAssertNil(try decode(#"{}"#))
    }

    func testDecodesNewValues() throws {
        XCTAssertEqual(try decode(#"{"platform":"google-meet"}"#), .googleMeet)
        XCTAssertEqual(try decode(#"{"platform":"zoom"}"#), .zoom)
    }

    func testUnknownValueFallsBackToOther() throws {
        XCTAssertEqual(try decode(#"{"platform":"jitsi"}"#), .other)
    }

    func testRoundTrip() throws {
        let data = try JSONEncoder().encode(Box(platform: .googleMeet))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"platform":"google-meet"}"#)
    }
}

final class DetectedCallTitleTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-09-30T14:05:00Z")!
    private let gb = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!

    func testAppName() {
        XCTAssertEqual(DetectedCallTitle.make(appName: "Zoom", at: date, locale: gb, timeZone: utc), "Zoom call 14:05")
        XCTAssertEqual(DetectedCallTitle.make(appName: "Microsoft Teams", at: date, locale: gb, timeZone: utc), "Teams call 14:05")
    }

    func testBrowserBecomesWebCall() {
        XCTAssertEqual(DetectedCallTitle.make(appName: "Google Chrome", at: date, locale: gb, timeZone: utc), "Web call 14:05")
    }

    func testNoApp() {
        XCTAssertEqual(DetectedCallTitle.make(appName: nil, at: date, locale: gb, timeZone: utc), "Call 14:05")
        XCTAssertEqual(DetectedCallTitle.make(appName: "  ", at: date, locale: gb, timeZone: utc), "Call 14:05")
    }
}
