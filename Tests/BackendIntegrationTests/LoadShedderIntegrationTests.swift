//
//  Copyright RevenueCat Inc. All Rights Reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://opensource.org/licenses/MIT
//
//  LoadShedderIntegrationTests.swift
//
//  Created by Nacho Soto on 3/21/23.

import Nimble
@testable import RevenueCat
import StoreKit
import XCTest

class LoadShedderStoreKit2IntegrationTests: LoadShedderStoreKit1IntegrationTests {

    override class var storeKit2Setting: StoreKit2Setting {
        return .enabledForCompatibleDevices
    }

}

class LoadShedderStoreKit1IntegrationTests: BaseStoreKitIntegrationTests {

    override var apiKey: String { return Constants.loadShedderApiKey }

    override class var storeKit2Setting: StoreKit2Setting {
        return .disabled
    }

    // temporarily disabling signature verification for load shedder until signing is
    // supported in it.
    override class var responseVerificationMode: Signing.ResponseVerificationMode {
        return .disabled
    }

    func testCanGetOfferings() async throws {
        let receivedOfferings = try await Purchases.shared.offerings()
        expect(receivedOfferings.all).toNot(beEmpty())
    }

    func testCanPurchasePackage() async throws {
        try await self.purchaseMonthlyOffering()
    }

    @available(iOS 15.0, tvOS 15.0, watchOS 8.0, macOS 12.0, *)
    func testProductEntitlementMapping() async throws {
        try AvailabilityChecks.iOS15APIAvailableOrSkipTest()

        XCTExpectFailure("Endpoint is not available yet")

        let result = try await Purchases.shared.productEntitlementMapping()
        expect(result.entitlementsByProduct).toNot(beEmpty())
    }

}
