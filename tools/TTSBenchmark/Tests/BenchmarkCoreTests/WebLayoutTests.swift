import XCTest
import AppKit
@preconcurrency import WebKit
@testable import BenchmarkCore

/// Tests our source in an isolated, memory-only WebKit component. It never
/// accesses a browser tab, file URL, real recording, or operator preferences.
@MainActor final class WebLayoutTests: XCTestCase {
    final class Navigation: NSObject, WKNavigationDelegate {
        let ready: XCTestExpectation
        var error: Error?
        init(_ ready: XCTestExpectation) { self.ready = ready }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready.fulfill() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.error = error; ready.fulfill()
        }
    }

    func testWebKitInitializesAndAlignsControlsAtDesktopAndNarrowWidths() async throws {
        _ = NSApplication.shared
        let runID = String(repeating: "a", count: 64)
        let progress = BracketProgress(runID: runID, sourceRevision: String(repeating: "b", count: 64), decisions: [], history: [], retained: [])
        let participants = (1...4).map { WebBracket.Participant(id: "voice-\($0)", label: "Voice \($0)", clips: ["layout": "blob:synthetic-layout-audio"]) }
        let seed = WebBracket.Seed(runID: runID, sourceRevision: progress.sourceRevision, participants: participants,
            passages: [Passage(id: "layout", role: "calibration", text: "Original synthetic layout fixture.")], progress: progress)
        let html = try WebBracket.resource("bracket-template", extension: "html")
            .replacingOccurrences(of: "/*__STYLE__*/", with: WebBracket.resource("style", extension: "css"))
            .replacingOccurrences(of: "/*__ENGINE__*/", with: WebBracket.resource("engine", extension: "js"))
            .replacingOccurrences(of: "/*__APP__*/", with: WebBracket.resource("app", extension: "js"))
            .replacingOccurrences(of: "__SEED_JSON__", with: String(decoding: Files.encoder.encode(seed), as: UTF8.self))
        for width in [360, 744, 1024] {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1600), configuration: configuration)
            let ready = expectation(description: "Synthetic WebKit layout \(width)")
            let navigation = Navigation(ready); view.navigationDelegate = navigation
            view.loadHTMLString(html, baseURL: nil)
            await fulfillment(of: [ready], timeout: 15)
            XCTAssertNil(navigation.error)
            let script = #"""
            JSON.stringify((()=>{
              const rect=s=>{let r=document.querySelector(s).getBoundingClientRect();return {x:r.x,y:r.y,right:r.right,bottom:r.bottom,width:r.width,height:r.height};};
              return {loaded:!document.getElementById('app').hidden&&document.getElementById('startup-status').hidden,
                font:getComputedStyle(document.body).fontFamily,viewport:innerWidth,scroll:document.documentElement.scrollWidth,
                a:rect('#audio-a'),b:rect('#audio-b'),preferA:rect('[data-choice="a"]'),preferB:rect('[data-choice="b"]'),
                notes:rect('#notes'),label:rect('.notes-label'),save:rect('#submit'),tie:rect('[data-choice="tie"]'),
                neither:rect('[data-choice="neither"]'),pause:rect('[data-choice="defer"]')};
            })())
            """#
            let raw = try await view.evaluateJavaScript(script)
            let json = try XCTUnwrap(raw as? String)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(result["loaded"] as? Bool, true, "App did not initialize at \(width)px")
            XCTAssertTrue((result["font"] as? String)?.contains("sans-serif") == true)
            XCTAssertLessThanOrEqual((result["scroll"] as? Double) ?? .infinity, Double(width) + 1)
            func value(_ name: String, _ key: String) -> Double { (result[name] as? [String: Double])?[key] ?? .nan }
            XCTAssertEqual(value("a", "x"), value("preferA", "x"), accuracy: 1)
            XCTAssertEqual(value("a", "width"), value("preferA", "width"), accuracy: 1)
            XCTAssertEqual(value("b", "x"), value("preferB", "x"), accuracy: 1)
            XCTAssertEqual(value("b", "width"), value("preferB", "width"), accuracy: 1)
            XCTAssertEqual(value("notes", "x"), value("a", "x"), accuracy: 1)
            XCTAssertEqual(value("notes", "right"), value("b", "right"), accuracy: 1)
            XCTAssertEqual(value("save", "x"), value("notes", "x"), accuracy: 1)
            XCTAssertGreaterThanOrEqual(value("notes", "y"), value("label", "bottom"))
            for control in ["a", "b", "preferA", "preferB", "tie", "neither", "pause", "save"] {
                XCTAssertGreaterThanOrEqual(value(control, "height"), 44)
            }
            if width > 650 {
                XCTAssertEqual(value("a", "y"), value("b", "y"), accuracy: 1)
                XCTAssertEqual(value("preferA", "y"), value("preferB", "y"), accuracy: 1)
            } else { XCTAssertGreaterThan(value("b", "y"), value("preferA", "bottom")) }
            view.stopLoading(); view.navigationDelegate = nil
        }
    }
}
