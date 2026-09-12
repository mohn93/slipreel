import Cocoa
import FlutterMacOS
import StoreKit
import AuthenticationServices

/// Retained by the window. StoreKit is unreachable in the direct edition.
@MainActor
final class StoreBridge: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding {
  private let channel: FlutterMethodChannel
  private weak var window: NSWindow?
  private var listener: Task<Void, Never>?
  private var products: [Product] = []
  private var buying = false
  private var appleResult: FlutterResult?
  private var authorization: ASAuthorizationController?
  private let productIDs: Set<String> = [
    "com.slipreel.store.monthly",
    "com.slipreel.store.yearly"
  ]
  static var isStore: Bool {
    #if APP_STORE
    return true
    #else
    return false
    #endif
  }

  init(messenger: FlutterBinaryMessenger, window: NSWindow) {
    self.channel = FlutterMethodChannel(name: "slipreel/store", binaryMessenger: messenger)
    self.window = window
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      if call.method == "channel" { result(Self.isStore ? "app-store" : "direct"); return }
      guard Self.isStore else {
        result(FlutterError(code: "WRONG_EDITION", message: "Store purchases are unavailable in this edition.", details: nil)); return
      }
      Task { @MainActor in
        do { try await self.handle(call, result: result) }
        catch {
          result(FlutterError(code: "STORE_UNAVAILABLE", message: "The App Store could not complete this request. Please try again.", details: nil))
        }
      }
    }
    if Self.isStore {
      listener = Task { [weak self] in
        for await verification in Transaction.updates {
          guard let self, !Task.isCancelled else { return }
          if case .verified(let transaction) = verification,
             self.productIDs.contains(transaction.productID) {
            // Access is derived from currentEntitlements, including revocations.
            self.channel.invokeMethod("transactionsChanged", arguments: nil)
            await transaction.finish()
          }
        }
      }
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) async throws {
    switch call.method {
    case "products":
      products = try await Product.products(for: productIDs)
      result(products.sorted { $0.price < $1.price }.map { product -> [String: Any] in
        var data: [String: Any] = ["id": product.id, "title": product.displayName,
                                    "price": product.displayPrice,
                                    "priceValue": NSDecimalNumber(decimal: product.price).doubleValue,
                                    "currencyCode": product.priceFormatStyle.currencyCode]
        if let period = product.subscription?.subscriptionPeriod {
          let unit: String
          switch period.unit {
          case .day: unit = "day"
          case .week: unit = "week"
          case .month: unit = "month"
          case .year: unit = "year"
          @unknown default: unit = "period"
          }
          data["period"] = period.value == 1 ? unit : "\(period.value) \(unit)s"
        }
        return data
      })
    case "entitlement":
      var selected: Transaction?
      for await verification in Transaction.currentEntitlements {
        guard case .verified(let transaction) = verification,
              productIDs.contains(transaction.productID),
              transaction.revocationDate == nil, !transaction.isUpgraded,
              transaction.productType == .autoRenewable,
              transaction.expirationDate.map({ $0 > Date() }) ?? false else { continue }
        // Monthly and yearly plans grant the same Pro access.
        if selected == nil ||
          (selected!.expirationDate != nil && transaction.expirationDate! > selected!.expirationDate!) {
          selected = transaction
        }
      }
      var data: [String: Any] = [:]
      if let selected {
        data["productId"] = selected.productID
        if let expiry = selected.expirationDate { data["expiresAt"] = expiry.timeIntervalSince1970 * 1000 }
      }
      result(data)
    case "purchase":
      guard !buying, let args = call.arguments as? [String: Any],
            let id = args["id"] as? String, productIDs.contains(id) else {
        result(FlutterError(code: "INVALID_PURCHASE", message: "Purchase unavailable.", details: nil)); return
      }
      buying = true
      defer { buying = false }
      guard let product = try await Product.products(for: [id]).first else {
        result(FlutterError(code: "PRODUCT_UNAVAILABLE", message: "This plan is unavailable in your storefront.", details: nil)); return
      }
      guard let tokenString = args["appAccountToken"] as? String,
            let accountToken = UUID(uuidString: tokenString) else {
        result(FlutterError(code: "SIGN_IN_REQUIRED", message: "Sign in to link your subscription to Slipreel.", details: nil)); return
      }
      switch try await product.purchase(options: [.appAccountToken(accountToken)]) {
      case .success(let verification):
        guard case .verified(let transaction) = verification,
              transaction.productID == id else {
          result(FlutterError(code: "UNVERIFIED", message: "Apple could not verify this purchase. Try Restore purchases.", details: nil)); return
        }
        channel.invokeMethod("transactionsChanged", arguments: nil)
        await transaction.finish()
        result("purchased")
      case .pending: result("pending")
      case .userCancelled: result("cancelled")
      @unknown default: result("pending")
      }
    case "signedTransactions":
      var transactions: [String] = []
      for await verification in Transaction.currentEntitlements {
        if case .verified(let transaction) = verification, productIDs.contains(transaction.productID) {
          transactions.append(verification.jwsRepresentation)
        }
      }
      result(transactions)
    case "restore":
      try await AppStore.sync()
      channel.invokeMethod("transactionsChanged", arguments: nil)
      result(nil)
    case "manageSubscriptions":
      NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/account/subscriptions")!)
      result(nil)
    case "appleSignIn":
      guard appleResult == nil, let args = call.arguments as? [String: String],
            let nonce = args["nonce"], let state = args["state"] else {
        result(FlutterError(code: "AUTH_BUSY", message: "Sign-in is already running.", details: nil)); return
      }
      appleResult = result
      let request = ASAuthorizationAppleIDProvider().createRequest()
      request.requestedScopes = [.email]
      request.nonce = nonce
      request.state = state
      let controller = ASAuthorizationController(authorizationRequests: [request])
      controller.delegate = self
      controller.presentationContextProvider = self
      authorization = controller
      controller.performRequests()
    default: result(FlutterMethodNotImplemented)
    }
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    window ?? NSApplication.shared.windows[0]
  }
  func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
    defer { appleResult = nil; self.authorization = nil }
    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
          let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
      appleResult?(FlutterError(code: "AUTH_FAILED", message: "Apple sign-in could not be verified.", details: nil)); return
    }
    appleResult?(["identityToken": token, "state": credential.state ?? "",
                  "code": credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) } ?? ""])
  }
  func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
    let cancelled = (error as? ASAuthorizationError)?.code == .canceled
    appleResult?(FlutterError(code: cancelled ? "AUTH_CANCELLED" : "AUTH_FAILED",
                             message: cancelled ? "Sign-in cancelled." : "Apple sign-in is unavailable. Try again.", details: nil))
    appleResult = nil
    authorization = nil
  }
}
