import Foundation
import StoreKit

/// Owns the StoreKit 2 interactions for the xTranscript Pro yearly
/// subscription. The `isPro` published property is the single source of
/// truth used by `TranscriptionViewModel` to decide whether to enforce
/// the 5-minute Free limit, and by `SidebarView` / `UpgradeView` for UI
/// state.
///
/// Verification is local — `Transaction.verificationResult.payloadValue`
/// uses StoreKit 2's built-in JWS check against Apple's public key. No
/// receipt-validation server is required for an audio-only desktop app.
@MainActor
final class SubscriptionManager: ObservableObject {

    /// Apple App Store product ID for the yearly subscription. Must match
    /// the entry in `Transcript/Configuration/Products.storekit` and the
    /// product registered in App Store Connect.
    static let proYearlyProductID = "net.eric_nicolas.xtranscript.pro.yearly"

    @Published private(set) var isPro: Bool = false
    @Published private(set) var product: Product? = nil
    @Published private(set) var purchaseInFlight: Bool = false
    @Published var lastError: String? = nil

    private var updatesTask: Task<Void, Never>? = nil

    init() {
        print("[Subs] init")
        // Diagnostic: when Xcode launches the app under a `.storekit`
        // configuration, it injects an env var with the resolved path.
        // If we see it, the test session is live; if not, StoreKit is
        // talking to the real App Store.
        let env = ProcessInfo.processInfo.environment
        let kitVars = env.filter { $0.key.lowercased().contains("storekit") || $0.key.lowercased().contains("sktest") }
        if kitVars.isEmpty {
            print("[Subs] WARNING: no StoreKitTest-* env var present → app is talking to the LIVE App Store, not the .storekit config.")
        } else {
            print("[Subs] StoreKitTest env detected:")
            for (k, v) in kitVars { print("  \(k) = \(v)") }
        }
        // Listen for transactions that arrive after init (renewals, refunds,
        // purchases made on another device, …).
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        // Resolve the current entitlement state and load the product.
        Task { [weak self] in
            print("[Subs] init Task: refreshEntitlements()…")
            await self?.refreshEntitlements()
            print("[Subs] init Task: loadProduct()…")
            await self?.loadProduct()
            print("[Subs] init Task done")
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Public actions

    func loadProduct() async {
        print("[Subs] loadProduct: querying Product.products(for: [\(Self.proYearlyProductID)])…")
        do {
            let products = try await Product.products(for: [Self.proYearlyProductID])
            print("[Subs] loadProduct: returned \(products.count) product(s): \(products.map { $0.id })")
            self.product = products.first
            if products.isEmpty {
                self.lastError = "StoreKit returned no products for ID \(Self.proYearlyProductID). Check Products.storekit ↔ SubscriptionManager.proYearlyProductID and the scheme's StoreKit config."
            }
        } catch {
            print("[Subs] loadProduct: threw \(error)")
            self.lastError = "Couldn't load subscription product: \(error.localizedDescription)"
        }
    }

    /// Attempt to purchase the yearly subscription. Returns true on success.
    @discardableResult
    func purchase() async -> Bool {
        guard let product else {
            await loadProduct()
            guard self.product != nil else {
                lastError = "Subscription product not available."
                return false
            }
            return await purchase()
        }

        purchaseInFlight = true
        defer { purchaseInFlight = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                isPro = true
                return true
            case .userCancelled:
                return false
            case .pending:
                // Ask-to-Buy / SCA flow — the listener will pick it up later.
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = "Purchase failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Re-pull entitlements from Apple and reflect the result in `isPro`.
    /// Required by App Store Guideline 3.1.1 ("Restore Purchases").
    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            lastError = "Couldn't reach the App Store: \(error.localizedDescription)"
        }
        await refreshEntitlements()
    }

    // MARK: - Internals

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard let transaction = try? checkVerified(result) else { return }
        await transaction.finish()
        await refreshEntitlements()
    }

    private func refreshEntitlements() async {
        print("[Subs] refreshEntitlements: walking Transaction.currentEntitlements…")
        var nowPro = false
        var seen = 0
        for await result in Transaction.currentEntitlements {
            seen += 1
            guard let transaction = try? checkVerified(result) else { continue }
            if transaction.productID == Self.proYearlyProductID,
               transaction.revocationDate == nil {
                nowPro = true
            }
        }
        print("[Subs] refreshEntitlements: saw \(seen) entitlement(s), isPro=\(nowPro)")
        if nowPro != isPro { isPro = nowPro }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value):
            return value
        case .unverified(_, let error):
            throw error
        }
    }
}
