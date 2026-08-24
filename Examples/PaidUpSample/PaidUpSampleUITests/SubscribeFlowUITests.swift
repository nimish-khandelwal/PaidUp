//
//  SubscribeFlowUITests.swift
//  PaidUp
//
//  Created by Nimish Khandelwal.
//

import StoreKitTest
import XCTest

/// End-to-end proof driven purely through the UI: tap *Subscribe* against the
/// StoreKit configuration, see the PRO badge; expire the subscription behind
/// the app's back, relaunch, and the badge is gone — cross-launch correctness.
final class SubscribeFlowUITests: XCTestCase {
    private var session: SKTestSession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        session = try SKTestSession(configurationFileNamed: "PaidUp")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() {
        session.clearTransactions()
        session = nil
    }

    func testSubscribeShowsProBadgeAndExpiryClearsItAcrossRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-paidUpResetCache"]
        app.launch()

        let badge = app.staticTexts["proBadge"]
        let subscribe = app.buttons["subscribeButton"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 5))
        XCTAssertFalse(badge.exists)

        subscribe.tap()
        XCTAssertTrue(badge.waitForExistence(timeout: 90), "PRO badge appears after purchase")

        try session.expireSubscription(productIdentifier: "pro.monthly")
        app.terminate()
        app.launchArguments = []
        app.launch()

        XCTAssertTrue(subscribe.waitForExistence(timeout: 30), "app relaunched")
        let deadline = Date().addingTimeInterval(120)
        while badge.exists, Date() < deadline {
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 1)
            app.activate()
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertFalse(badge.exists, "PRO badge still visible after expiry and relaunch")
        XCTAssertTrue(app.staticTexts["entitlementsLabel"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["entitlementsLabel"].label.contains("pro.monthly"))
    }
}
