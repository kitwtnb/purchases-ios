//
//  Copyright RevenueCat Inc. All Rights Reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://opensource.org/licenses/MIT
//
//  PurchasesOrchestrator.swift
//
//  Created by Andrés Boedo on 10/8/21.

import Foundation
import StoreKit

@objc protocol PurchasesOrchestratorDelegate {

    func shouldPurchasePromoProduct(_ product: StoreProduct,
                                    defermentBlock: @escaping DeferredPromotionalPurchaseBlock)

}

// swiftlint:disable file_length type_body_length
class PurchasesOrchestrator {

    var finishTransactions: Bool { systemInfo.finishTransactions }
    var allowSharingAppStoreAccount: Bool {
        get {
            return _allowSharingAppStoreAccount ?? identityManager.currentUserIsAnonymous
        }
        set {
            _allowSharingAppStoreAccount = newValue
        }
    }

    @objc weak var delegate: PurchasesOrchestratorDelegate?

    private var _allowSharingAppStoreAccount: Bool?
    private var presentedOfferingIDsByProductID: [String: String] = [:]
    private var purchaseCompleteCallbacksByProductID: [String: PurchaseCompletedBlock] = [:]

    private var appUserID: String { identityManager.currentAppUserID }
    private var unsyncedAttributes: SubscriberAttributeDict {
        subscriberAttributesManager.unsyncedAttributesByKey(appUserID: self.appUserID)
    }

    private let productsManager: ProductsManager
    private let storeKitWrapper: StoreKitWrapper
    private let systemInfo: SystemInfo
    private let subscriberAttributesManager: SubscriberAttributesManager
    private let operationDispatcher: OperationDispatcher
    private let receiptFetcher: ReceiptFetcher
    private let customerInfoManager: CustomerInfoManager
    private let backend: Backend
    private let identityManager: IdentityManager
    private let transactionsManager: TransactionsManager
    private let deviceCache: DeviceCache
    private let manageSubscriptionsHelper: ManageSubscriptionsHelper
    private let beginRefundRequestHelper: BeginRefundRequestHelper
    private let lock = NSRecursiveLock()

    @available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
    lazy var storeKit2Listener = StoreKit2TransactionListener(delegate: self)

    init(productsManager: ProductsManager,
         storeKitWrapper: StoreKitWrapper,
         systemInfo: SystemInfo,
         subscriberAttributesManager: SubscriberAttributesManager,
         operationDispatcher: OperationDispatcher,
         receiptFetcher: ReceiptFetcher,
         customerInfoManager: CustomerInfoManager,
         backend: Backend,
         identityManager: IdentityManager,
         transactionsManager: TransactionsManager,
         deviceCache: DeviceCache,
         manageSubscriptionsHelper: ManageSubscriptionsHelper,
         beginRefundRequestHelper: BeginRefundRequestHelper) {
        self.productsManager = productsManager
        self.storeKitWrapper = storeKitWrapper
        self.systemInfo = systemInfo
        self.subscriberAttributesManager = subscriberAttributesManager
        self.operationDispatcher = operationDispatcher
        self.receiptFetcher = receiptFetcher
        self.customerInfoManager = customerInfoManager
        self.backend = backend
        self.identityManager = identityManager
        self.transactionsManager = transactionsManager
        self.deviceCache = deviceCache
        self.manageSubscriptionsHelper = manageSubscriptionsHelper
        self.beginRefundRequestHelper = beginRefundRequestHelper

        if #available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *) {
            storeKit2Listener.listenForTransactions()
        }
    }

    func restorePurchases(completion: ((CustomerInfo?, Error?) -> Void)?) {
        syncPurchases(receiptRefreshPolicy: .always, isRestore: true, completion: completion)
    }

    func syncPurchases(completion: ((CustomerInfo?, Error?) -> Void)? = nil) {
        syncPurchases(receiptRefreshPolicy: .never,
                      isRestore: allowSharingAppStoreAccount,
                      completion: completion)
    }

    func products(withIdentifiers identifiers: [String], completion: @escaping ([StoreProduct]) -> Void) {
        let productIdentifiersSet = Set(identifiers)
        guard !productIdentifiersSet.isEmpty else {
            operationDispatcher.dispatchOnMainThread { completion([]) }
            return
        }

        productsManager.products(withIdentifiers: productIdentifiersSet) { products in
            self.operationDispatcher.dispatchOnMainThread {
                completion(Array(products.value ?? []))
            }
        }
    }

    func productsFromOptimalStoreKitVersion(withIdentifiers identifiers: [String],
                                            completion: @escaping ([StoreProduct]) -> Void) {
        let productIdentifiersSet = Set(identifiers)
        guard !productIdentifiersSet.isEmpty else {
            operationDispatcher.dispatchOnMainThread { completion([]) }
            return
        }

        productsManager.products(withIdentifiers: productIdentifiersSet) { products in
            self.operationDispatcher.dispatchOnMainThread {
                completion(Array(products.value ?? []))
            }
        }
    }

    @available(iOS 12.2, macOS 10.14.4, watchOS 6.2, macCatalyst 13.0, tvOS 12.2, *)
    func promotionalOffer(forProductDiscount productDiscount: StoreProductDiscountType,
                          product: SK1Product,
                          completion: @escaping (PromotionalOffer?, Error?) -> Void) {
        guard let discountIdentifier = productDiscount.offerIdentifier else {
            completion(nil, ErrorUtils.productDiscountMissingIdentifierError())
            return
        }

        guard let subscriptionGroupIdentifier = product.subscriptionGroupIdentifier else {
            completion(nil, ErrorUtils.productDiscountMissingSubscriptionGroupIdentifierError())
            return
        }

        receiptFetcher.receiptData(refreshPolicy: .onlyIfEmpty) { receiptData in
            guard let receiptData = receiptData,
                  !receiptData.isEmpty else {
                      completion(nil, ErrorUtils.missingReceiptFileError())
                      return
                  }

            self.backend.post(
                offerIdForSigning: discountIdentifier,
                productIdentifier: product.productIdentifier,
                subscriptionGroup: subscriptionGroupIdentifier,
                receiptData: receiptData,
                appUserID: self.appUserID
            ) { signature, keyIdentifier, nonce, timestamp, error in
                if let error = error {
                    completion(nil, error)
                    return
                }
                guard let keyIdentifier = keyIdentifier,
                      let nonce = nonce,
                      let signature = signature,
                      let timestamp = timestamp else {
                          completion(
                            nil,
                            ErrorUtils.unexpectedBackendResponseError(extraUserInfo: [
                                "keyIdentifier": String(describing: keyIdentifier),
                                "nonce": String(describing: nonce),
                                "signature": String(describing: signature),
                                "timestamp": String(describing: timestamp)
                            ])
                          )
                          return
                      }

                let promotionalOffer = PromotionalOffer(identifier: discountIdentifier,
                                                        keyIdentifier: keyIdentifier,
                                                        nonce: nonce,
                                                        signature: signature,
                                                        timestamp: timestamp)
                completion(promotionalOffer, nil)
            }
        }
    }

    func purchase(product: StoreProduct,
                  package: Package?,
                  completion: @escaping PurchaseCompletedBlock) {
        if let sk1Product = product.sk1Product {
            let payment = storeKitWrapper.payment(withProduct: sk1Product)

            purchase(sk1Product: sk1Product,
                     payment: payment,
                     package: package,
                     completion: completion)
        } else if #available(iOS 15.0, tvOS 15.0, watchOS 8.0, macOS 12.0, *),
                  let sk2Product = product.sk2Product {
            purchase(sk2Product: sk2Product,
                     completion: completion)
        } else {
            fatalError("Unrecognized product: \(product)")
        }
    }

    @available(iOS 12.2, macOS 10.14.4, watchOS 6.2, macCatalyst 13.0, tvOS 12.2, *)
    func purchase(product: StoreProduct,
                  package: Package?,
                  discount: StoreProductDiscountType,
                  completion: @escaping PurchaseCompletedBlock) {
        if let sk1Product = product.sk1Product {
            purchase(sk1Product: sk1Product,
                     storeProductDiscount: discount,
                     package: package,
                     completion: completion)
        } else if #available(iOS 15.0, tvOS 15.0, watchOS 8.0, macOS 12.0, *),
                  let sk2Product = product.sk2Product {
            // todo: add support for SK2 discounts
            purchase(sk2Product: sk2Product,
                     completion: completion)
        } else {
            fatalError("Unrecognized product: \(product)")
        }
    }

    @available(iOS 12.2, macOS 10.14.4, watchOS 6.2, macCatalyst 13.0, tvOS 12.2, *)
    func purchase(sk1Product: SK1Product,
                  storeProductDiscount: StoreProductDiscountType,
                  package: Package?,
                  completion: @escaping PurchaseCompletedBlock) {
        self.promotionalOffer(forProductDiscount: storeProductDiscount,
                              product: sk1Product) { [unowned self] promotionalOffer, error in
            guard let promotionalOffer = promotionalOffer else {
                completion(nil, nil, error, false)
                return
            }

            let discount = promotionalOffer.sk1PromotionalOffer
            let payment = self.storeKitWrapper.payment(withProduct: sk1Product, discount: discount)
            self.purchase(sk1Product: sk1Product,
                          payment: payment,
                          package: package,
                          completion: completion)
        }
    }

    func purchase(sk1Product: SK1Product,
                  payment: SKMutablePayment,
                  package: Package?,
                  completion: @escaping PurchaseCompletedBlock) {
        Logger.debug(String(format: "Make purchase called: %@", #function))
        guard let productIdentifier = sk1Product.extractProductIdentifier(withPayment: payment) else {
            Logger.error(Strings.purchase.could_not_purchase_product_id_not_found)
            let errorMessage = "There was a problem purchasing the product: productIdentifier was nil"
            completion(nil, nil, ErrorUtils.unknownError(message: errorMessage), false)
            return
        }

        if !self.finishTransactions {
            Logger.warn(Strings.purchase.purchasing_with_observer_mode_and_finish_transactions_false_warning)
        }

        payment.applicationUsername = appUserID
        preventPurchasePopupCallFromTriggeringCacheRefresh(appUserID: appUserID)

        if let presentedOfferingIdentifier = package?.offeringIdentifier {
            Logger.purchase(
                Strings.purchase.purchasing_product_from_package(
                    productIdentifier: productIdentifier,
                    offeringIdentifier: presentedOfferingIdentifier
                )
            )
            lock.lock()
            presentedOfferingIDsByProductID[productIdentifier] = presentedOfferingIdentifier
            lock.unlock()

        } else {
            Logger.purchase(Strings.purchase.purchasing_product(productIdentifier: productIdentifier))
        }

        productsManager.cacheProduct(sk1Product)

        lock.lock()
        defer {
            lock.unlock()
        }

        guard purchaseCompleteCallbacksByProductID[productIdentifier] == nil else {
            completion(nil, nil, ErrorUtils.operationAlreadyInProgressError(), false)
            return
        }
        purchaseCompleteCallbacksByProductID[productIdentifier] = completion
        storeKitWrapper.add(payment)
    }

    @available(iOS 15.0, tvOS 15.0, watchOS 8.0, macOS 12.0, *)
    func purchase(sk2Product product: SK2Product, completion: @escaping PurchaseCompletedBlock) {
        _ = Task<Void, Never> {
            let result = await purchase(sk2Product: product)
            DispatchQueue.main.async {
                switch result {
                case .failure(let error) where error is StoreKitError:
                    completion(nil, nil, ErrorUtils.purchasesError(withStoreKitError: error), false)
                case .failure(let error):
                    completion(nil, nil, error, false)
                case .success(let (customerInfo, userCancelled)):
                    // todo: change API and send transaction
                    if userCancelled {
                        completion(nil, nil, ErrorUtils.purchaseCancelledError(), userCancelled)
                    } else {
                        completion(nil, customerInfo, nil, userCancelled)
                    }
                }
            }
        }
    }

#if os(iOS) || os(macOS)

    @available(watchOS, unavailable)
    @available(tvOS, unavailable)
    func showManageSubscription(completion: @escaping (Error?) -> Void) {
        self.manageSubscriptionsHelper.showManageSubscriptions { result in
            switch result {
            case .failure(let error):
                completion(error)
            case .success:
                completion(nil)
            }
        }
    }
#endif

#if os(iOS)

    @available(iOS 15.0, *)
    @available(macOS, unavailable)
    @available(watchOS, unavailable)
    @available(tvOS, unavailable)
    func beginRefundRequest(forProduct productID: String) async throws -> RefundRequestStatus {
        return try await beginRefundRequestHelper.beginRefundRequest(forProduct: productID)
    }

    @available(iOS 15.0, *)
    @available(macOS, unavailable)
    @available(watchOS, unavailable)
    @available(tvOS, unavailable)
    func beginRefundRequestForActiveEntitlement() async throws -> RefundRequestStatus {
        return try await beginRefundRequestHelper.beginRefundRequestForActiveEntitlement()
    }

    @available(iOS 15.0, *)
    @available(macOS, unavailable)
    @available(watchOS, unavailable)
    @available(tvOS, unavailable)
    func beginRefundRequest(forEntitlement entitlementID: String) async throws -> RefundRequestStatus {
        return try await beginRefundRequestHelper.beginRefundRequest(forEntitlement: entitlementID)
    }

#endif

}

extension PurchasesOrchestrator: StoreKitWrapperDelegate {

    func storeKitWrapper(_ storeKitWrapper: StoreKitWrapper, updatedTransaction transaction: SKPaymentTransaction) {
        switch transaction.transactionState {
        case .restored, // for observer mode
             .purchased:
            handlePurchasedTransaction(transaction)
        case .purchasing:
            break
        case .failed:
            handleFailedTransaction(transaction)
        case .deferred:
            handleDeferredTransaction(transaction)
        @unknown default:
            Logger.warn("unhandled transaction state!")
        }
    }

    func storeKitWrapper(_ storeKitWrapper: StoreKitWrapper,
                         removedTransaction transaction: SKPaymentTransaction) {
        // unused for now
    }

    func storeKitWrapper(_ storeKitWrapper: StoreKitWrapper,
                         shouldAddStorePayment payment: SKPayment,
                         for product: SK1Product) -> Bool {
        productsManager.cacheProduct(product)
        guard let delegate = delegate else { return false }

        let storeProduct = StoreProduct(sk1Product: product)
        lock.lock()
        delegate.shouldPurchasePromoProduct(storeProduct) { completion in
            self.purchaseCompleteCallbacksByProductID[product.productIdentifier] = completion
            storeKitWrapper.add(payment)
        }
        lock.unlock()
        return false
    }

    func storeKitWrapper(_ storeKitWrapper: StoreKitWrapper,
                         didRevokeEntitlementsForProductIdentifiers productIdentifiers: [String]) {
        Logger.debug(Strings.purchase.entitlements_revoked_syncing_purchases(productIdentifiers: productIdentifiers))
        syncPurchases { _, _ in
            Logger.debug(Strings.purchase.purchases_synced)
        }
    }

}

// MARK: Transaction state updates.
private extension PurchasesOrchestrator {

    func handlePurchasedTransaction(_ transaction: SKPaymentTransaction) {
        receiptFetcher.receiptData(refreshPolicy: .onlyIfEmpty) { receiptData in
            if let receiptData = receiptData,
               !receiptData.isEmpty {
                self.fetchProductsAndPostReceipt(withTransaction: transaction, receiptData: receiptData)
            } else {
                self.handleReceiptPost(withTransaction: transaction,
                                       customerInfo: nil,
                                       subscriberAttributes: nil,
                                       error: ErrorUtils.missingReceiptFileError())
            }
        }
    }

    func handleFailedTransaction(_ transaction: SKPaymentTransaction) {
        if let error = transaction.error,
           let completion = getAndRemovePurchaseCompletedCallback(forTransaction: transaction) {
            let nsError = error as NSError
            let userCancelled = nsError.code == SKError.paymentCancelled.rawValue
            operationDispatcher.dispatchOnMainThread {
                completion(StoreTransaction(sk1Transaction: transaction),
                           nil,
                           ErrorUtils.purchasesError(withSKError: error),
                           userCancelled)
            }
        }

        if finishTransactions {
            storeKitWrapper.finishTransaction(transaction)
        }
    }

    func handleDeferredTransaction(_ transaction: SKPaymentTransaction) {
        let userCancelled: Bool
        if let error = transaction.error as NSError? {
            userCancelled = error.code == SKError.paymentCancelled.rawValue
        } else {
            userCancelled = false
        }

        guard let completion = getAndRemovePurchaseCompletedCallback(forTransaction: transaction) else {
            return
        }

        operationDispatcher.dispatchOnMainThread {
            completion(
                StoreTransaction(sk1Transaction: transaction),
                nil,
                ErrorUtils.paymentDeferredError(), userCancelled
            )
        }
    }

}

extension PurchasesOrchestrator: StoreKit2TransactionListenerDelegate {

    func transactionsUpdated() {
        // Need to restore if using observer mode (which is inverse of finishTransactions)
        let isRestore = !systemInfo.finishTransactions
        syncPurchases(receiptRefreshPolicy: .always, isRestore: isRestore, completion: nil)
    }

}

// MARK: Private funcs.
private extension PurchasesOrchestrator {

    func getAndRemovePurchaseCompletedCallback(
        forTransaction transaction: SKPaymentTransaction
    ) -> PurchaseCompletedBlock? {
        guard let productIdentifier = transaction.productIdentifier else {
            return nil
        }

        lock.lock()
        let completion = purchaseCompleteCallbacksByProductID.removeValue(forKey: productIdentifier)
        lock.unlock()
        return completion
    }

    func fetchProductsAndPostReceipt(withTransaction transaction: SKPaymentTransaction, receiptData: Data) {
        guard let productIdentifier = transaction.productIdentifier else {
            self.handleReceiptPost(withTransaction: transaction,
                                   customerInfo: nil,
                                   subscriberAttributes: nil,
                                   error: ErrorUtils.unknownError())
            return
        }

        self.products(withIdentifiers: [productIdentifier]) { products in
            self.postReceipt(withTransaction: transaction,
                             receiptData: receiptData,
                             products: Set(products))
        }
    }

    func postReceipt(withTransaction transaction: SKPaymentTransaction,
                     receiptData: Data,
                     products: Set<StoreProduct>) {
        var productData: ProductRequestData?
        var presentedOfferingID: String?
        if let product = products.first {
            let receivedProductData = ProductRequestData(with: product)
            productData = receivedProductData

            let productID = receivedProductData.productIdentifier
            let foundPresentedOfferingID = presentedOfferingIDsByProductID[productID]
            presentedOfferingID = foundPresentedOfferingID

            presentedOfferingIDsByProductID.removeValue(forKey: productID)
        }
        let unsyncedAttributes = unsyncedAttributes

        backend.post(receiptData: receiptData,
                     appUserID: appUserID,
                     isRestore: allowSharingAppStoreAccount,
                     productData: productData,
                     presentedOfferingIdentifier: presentedOfferingID,
                     observerMode: !finishTransactions,
                     subscriberAttributes: unsyncedAttributes) { customerInfo, error in
            self.handleReceiptPost(withTransaction: transaction,
                                   customerInfo: customerInfo,
                                   subscriberAttributes: unsyncedAttributes,
                                   error: error)
        }
    }

    func handleReceiptPost(withTransaction transaction: SKPaymentTransaction,
                           customerInfo: CustomerInfo?,
                           subscriberAttributes: SubscriberAttributeDict?,
                           error: Error?) {
        operationDispatcher.dispatchOnMainThread {
            let appUserID = self.appUserID
            self.markSyncedIfNeeded(subscriberAttributes: subscriberAttributes,
                                    appUserID: appUserID,
                                    error: error)

            let completion = self.getAndRemovePurchaseCompletedCallback(forTransaction: transaction)
            let nsError = error as NSError?
            let finishable = (nsError?.userInfo[ErrorDetails.finishableKey as String] as? NSNumber)?.boolValue ?? false

            let storeTransaction = StoreTransaction(sk1Transaction: transaction)

            if let customerInfo = customerInfo {
                self.customerInfoManager.cache(customerInfo: customerInfo, appUserID: appUserID)
                completion?(storeTransaction, customerInfo, nil, false)

                if self.finishTransactions {
                    self.storeKitWrapper.finishTransaction(transaction)
                }
            } else if finishable {
                completion?(storeTransaction, nil, error, false)
                if self.finishTransactions {
                    self.storeKitWrapper.finishTransaction(transaction)
                }
            } else {
                Logger.error(Strings.receipt.unknown_backend_error)
                completion?(storeTransaction, nil, error, false)
            }
        }
    }

    func markSyncedIfNeeded(subscriberAttributes: SubscriberAttributeDict?, appUserID: String, error: Error?) {
        if let error = error as NSError? {
            if !error.successfullySynced {
                return
            }
            Logger.error(Strings.attribution.subscriber_attributes_error(errors: error.subscriberAttributesErrors))
        }

        subscriberAttributesManager.markAttributesAsSynced(subscriberAttributes, appUserID: appUserID)
    }

    func syncPurchases(receiptRefreshPolicy: ReceiptRefreshPolicy,
                       isRestore: Bool,
                       completion: ((CustomerInfo?, Error?) -> Void)?) {
        if !self.allowSharingAppStoreAccount {
            Logger.warn(Strings.restore.restorepurchases_called_with_allow_sharing_appstore_account_false_warning)
        }

        let currentAppUserID = appUserID
        let unsyncedAttributes = unsyncedAttributes
        // Refresh the receipt and post to backend, this will allow the transactions to be transferred.
        // swiftlint:disable line_length
        // https://developer.apple.com/library/content/documentation/NetworkingInternet/Conceptual/StoreKitGuide/Chapters/Restoring.html
        // swiftlint:enable line_length
        receiptFetcher.receiptData(refreshPolicy: receiptRefreshPolicy) { receiptData in
            guard let receiptData = receiptData,
                  !receiptData.isEmpty else {
                      if self.systemInfo.isSandbox {
                          Logger.appleWarning(Strings.receipt.no_sandbox_receipt_restore)
                      }

                      if let completion = completion {
                          self.operationDispatcher.dispatchOnMainThread {
                              completion(nil, ErrorUtils.missingReceiptFileError())
                          }
                      }
                      return
                  }

            self.transactionsManager.customerHasTransactions(receiptData: receiptData) { hasTransactions in
                let cachedCustomerInfo = self.customerInfoManager.cachedCustomerInfo(appUserID: currentAppUserID)
                let hasOriginalPurchaseDate = cachedCustomerInfo?.originalPurchaseDate != nil

                if !hasTransactions && hasOriginalPurchaseDate {
                    if let completion = completion {
                        self.operationDispatcher.dispatchOnMainThread {
                            completion(cachedCustomerInfo, nil)
                        }
                    }
                    return
                }

                self.backend.post(receiptData: receiptData,
                                  appUserID: currentAppUserID,
                                  isRestore: isRestore,
                                  productData: nil,
                                  presentedOfferingIdentifier: nil,
                                  observerMode: !self.finishTransactions,
                                  subscriberAttributes: unsyncedAttributes) { customerInfo, error in
                    self.handleReceiptPost(withCustomerInfo: customerInfo,
                                           error: error,
                                           subscriberAttributes: unsyncedAttributes,
                                           completion: completion)
                }
            }
        }
    }

    func handleReceiptPost(withCustomerInfo customerInfo: CustomerInfo?,
                           error: Error?,
                           subscriberAttributes: SubscriberAttributeDict,
                           completion: ((CustomerInfo?, Error?) -> Void)?) {
        operationDispatcher.dispatchOnMainThread {
            if let customerInfo = customerInfo {
                self.customerInfoManager.cache(customerInfo: customerInfo, appUserID: self.appUserID)
            }

            self.markSyncedIfNeeded(subscriberAttributes: subscriberAttributes,
                                    appUserID: self.appUserID,
                                    error: error)

            if let completion = completion {
                self.operationDispatcher.dispatchOnMainThread {
                    completion(customerInfo, error)
                }
            }
        }
    }

    func preventPurchasePopupCallFromTriggeringCacheRefresh(appUserID: String) {
        deviceCache.setCacheTimestampToNowToPreventConcurrentCustomerInfoUpdates(appUserID: appUserID)
        deviceCache.setOfferingsCacheTimestampToNow()
    }

    @available(iOS 15.0, tvOS 15.0, watchOS 8.0, macOS 12.0, *)
    private func purchase(sk2Product: SK2Product) async -> Result<(CustomerInfo, Bool), Error> {
        do {
            let options: Set<Product.PurchaseOption> = [
                .simulatesAskToBuyInSandbox(Purchases.simulatesAskToBuyInSandbox)
            ]

            let result = try await sk2Product.purchase(options: options)
            let userCancelled = try await storeKit2Listener.handle(purchaseResult: result)

            return await withCheckedContinuation { continuation in
                syncPurchases(receiptRefreshPolicy: .always, isRestore: false) { customerInfo, error in
                    if let error = error {
                        continuation.resume(returning: .failure(error))
                        return
                    }
                    guard let customerInfo = customerInfo else {
                        continuation.resume(returning: .failure(ErrorUtils.unexpectedBackendResponseError()))
                        return
                    }

                    continuation.resume(returning: .success((customerInfo, userCancelled)))
                }
            }
        } catch {
            return .failure(error)
        }
    }

    func purchase(sk1Product: SK1Product, package: Package, completion: @escaping PurchaseCompletedBlock) {
        let payment = storeKitWrapper.payment(withProduct: sk1Product)
        purchase(sk1Product: sk1Product,
                 payment: payment,
                 package: package,
                 completion: completion)
    }

}
