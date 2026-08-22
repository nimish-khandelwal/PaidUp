//
//  SubscribeUITests.swift
//  Cheers Vegas Slots
//
//  Created by Nimish Khandelwal.
//

import StoreKitTest
import XCTest

/// End-to-end proof driven purely through the UI: tap *Subscribe* against the
/// StoreKit configuration, see the PRO badge; expire the subscription behind
/// the app's back, relaunch, and the badge is gone — cross-launch correctness.
final class SubscribeUITests: XCTestCase {
    private var session: SKTestSession!

    override func setUpWithError() throws {
        continueAfterFailure = false
        session = try SKTestSession(configurationFileNamed: "Entitled")
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
        app.launchArguments = ["-entitledResetCache"]
        app.launch()

        let badge = app.staticTexts["proBadge"]
        let subscribe = app.buttons["subscribeButton"]
        XCTAssertTrue(subscribe.waitForExistence(timeout: 5))
        XCTAssertFalse(badge.exists)

        subscribe.tap()
        XCTAssertTrue(badge.waitForExistence(timeout: 15), "PRO badge appears after purchase")

        try session.expireSubscription(productIdentifier: "pro.monthly")
        app.terminate()
        app.launchArguments = []
        app.launch()

        let gone = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: badge
        )
        wait(for: [gone], timeout: 15)
    }
}
