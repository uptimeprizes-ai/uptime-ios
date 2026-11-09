import Foundation
import StoreKit
import SwiftData

// MARK: - StoreCatalog
//
// Which store ids the app asks for, and which journey an owned id belongs
// to. Built from the manifest (single source of truth), never hand-written.
//
// A product id can never be renamed, and the store reports the id a purchase
// was made under forever. So restore recognises a journey's current id OR any
// retired one (`legacyProductIds`), while the store is only ever ASKED for
// current ids — a withdrawn product can never reappear in the storefront.
//
// The manifest carries the product ids for both stores: App Store Connect
// uses the same ids as Play. The Overture is journey_overture_lp on both,
// because Apple never reissues a deleted id (App Builder, 2026-10-10). The
// log reports how many the App Store returns, every launch.

struct StoreCatalog: Equatable {
    /// Current product id → journeyId. The only ids the store is asked for.
    let current: [String: String]
    /// Every id a purchase may have been made under → journeyId.
    let owned: [String: String]

    init(journeys: [ManifestJourney]) {
        var current: [String: String] = [:]
        var owned: [String: String] = [:]
        for journey in journeys {
            if !journey.productId.isEmpty {
                current[journey.productId] = journey.journeyId
                owned[journey.productId] = journey.journeyId
            }
            for legacy in journey.legacyProductIds ?? [] where !legacy.isEmpty {
                owned[legacy] = journey.journeyId
            }
        }
        self.current = current
        self.owned = owned
    }

    /// The ids to ask the store for, in a stable order for the log.
    var queryIds: [String] { current.keys.sorted() }

    func journeyId(forOwnedProductId productId: String) -> String? { owned[productId] }

    func currentProductId(forJourneyId journeyId: String) -> String? {
        current.first(where: { $0.value == journeyId })?.key
    }
}

// MARK: - StoreKitManager
//
// Every step of the purchase path announces itself in the device log under
// [STORE], on success as loudly as on failure (App Builder, 2026-09-26: on
// Android the silent success case hid a path that never ran for months).

@MainActor
class StoreKitManager: ObservableObject {

    static let catalog = StoreCatalog(journeys: UpTimeManifest.loadFromBundle()?.journeys ?? [])

    // MARK: - Published state

    @Published var products: [Product] = []
    @Published var purchasedProductIDs: Set<String> = []
    @Published var isLoading: Bool = false

    // MARK: - Private

    private var context: ModelContext?
    private var transactionListenerTask: Task<Void, Never>?

    // MARK: - Init / Deinit

    init() {
        transactionListenerTask = listenForTransactions()
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Setup

    func configure(context: ModelContext) {
        self.context = context
        ReferralCode.logLaunchState()
        Task {
            await fetchProducts()
            await restorePurchases()
        }
    }

    // MARK: - Fetch products

    func fetchProducts() async {
        isLoading = true
        defer { isLoading = false }
        let ids = Self.catalog.queryIds
        UpTimeLog.store.notice("[STORE] asking the App Store for \(ids.count, privacy: .public) product(s): \(ids.joined(separator: ", "), privacy: .public)")
        do {
            products = try await Product.products(for: ids)
            let answered = products.map { "\($0.id)=\($0.displayPrice)" }.sorted().joined(separator: ", ")
            UpTimeLog.store.notice("[STORE] App Store answered with \(self.products.count, privacy: .public)/\(ids.count, privacy: .public): \(answered.isEmpty ? "none" : answered, privacy: .public)")
            let missing = Set(ids).subtracting(products.map(\.id)).sorted()
            if !missing.isEmpty {
                UpTimeLog.store.notice("[STORE] not found in App Store Connect: \(missing.joined(separator: ", "), privacy: .public)")
            }
        } catch {
            UpTimeLog.store.error("[STORE] product request failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async throws -> Transaction? {
        // The referral code saved on this phone, if any, travels with the
        // purchase as appAccountToken; Apple carries it to the notifications
        // endpoint. No code → no token → no referral. Fixed per purchase.
        let code = ReferralCode.savedCode
        let token = ReferralCode.currentToken
        var options: Set<Product.PurchaseOption> = []
        if let token { options.insert(.appAccountToken(token)) }
        UpTimeLog.store.notice("[STORE] purchase started: \(product.id, privacy: .public) \(product.displayPrice, privacy: .public) referral=\(code ?? "none", privacy: .public) token=\(token?.uuidString.lowercased() ?? "none", privacy: .public)")
        let result = try await product.purchase(options: options)
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            // What Apple actually recorded on the transaction, not what was sent.
            UpTimeLog.store.notice("[STORE] purchase verified: \(product.id, privacy: .public) appAccountToken=\(transaction.appAccountToken?.uuidString.lowercased() ?? "none", privacy: .public)")
            applyEntitlement(productID: product.id, isNewPurchase: true)
            return transaction
        case .userCancelled:
            UpTimeLog.store.notice("[STORE] purchase cancelled: \(product.id, privacy: .public)")
            return nil
        case .pending:
            UpTimeLog.store.notice("[STORE] purchase pending approval: \(product.id, privacy: .public)")
            return nil
        @unknown default:
            UpTimeLog.store.notice("[STORE] purchase ended with an unknown result: \(product.id, privacy: .public)")
            return nil
        }
    }

    // MARK: - Restore purchases

    func restorePurchases() async {
        var ownedIds: [String] = []
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                ownedIds.append(transaction.productID)
                applyEntitlement(productID: transaction.productID, isNewPurchase: false)
            case .unverified(let transaction, let error):
                UpTimeLog.store.error("[STORE] unverified entitlement ignored: \(transaction.productID, privacy: .public) \(error, privacy: .public)")
            }
        }
        UpTimeLog.store.notice("[STORE] App Store reports \(ownedIds.count, privacy: .public) owned purchase(s): \(ownedIds.isEmpty ? "none" : ownedIds.sorted().joined(separator: ", "), privacy: .public)")
    }

    // MARK: - Transaction listener (purchases completed outside the app)

    private func listenForTransactions() -> Task<Void, Never> {
        Task(priority: .background) {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await MainActor.run {
                        UpTimeLog.store.notice("[STORE] transaction update: \(transaction.productID, privacy: .public)")
                        self.applyEntitlement(productID: transaction.productID, isNewPurchase: true)
                    }
                    await transaction.finish()
                }
            }
        }
    }

    // MARK: - Entitlement application

    /// Marks the journey an owned product belongs to as owned.
    ///
    /// A new purchase also makes that journey the active one (only one is
    /// active at a time; every journey keeps its own progress). A restore —
    /// which runs on every launch — never changes which journey is active,
    /// never moves a journey backwards, and never touches The Genesis: the
    /// catalog gate counts completed Genesis mornings, never ownership.
    private func applyEntitlement(productID: String, isNewPurchase: Bool) {
        guard let journeyId = Self.catalog.journeyId(forOwnedProductId: productID) else {
            UpTimeLog.store.error("[STORE] owned product matches no journey: \(productID, privacy: .public)")
            return
        }
        guard let context else {
            // Transaction.updates can deliver before configure(context:) runs.
            // The restore that configure performs picks this purchase up again.
            UpTimeLog.store.notice("[STORE] entitlement for \(productID, privacy: .public) arrived before the database was ready — the launch restore will apply it")
            return
        }

        purchasedProductIDs.insert(productID)

        guard let journeys = try? context.fetch(FetchDescriptor<JourneyEntity>()) else {
            UpTimeLog.store.error("[STORE] entitlement for \(productID, privacy: .public) not applied: journeys could not be read")
            return
        }
        guard let purchased = journeys.first(where: { $0.id == journeyId }) else {
            UpTimeLog.store.error("[STORE] entitlement for \(productID, privacy: .public) not applied: no journey row for \(journeyId, privacy: .public)")
            return
        }

        if purchased.purchaseState == "NOT_OWNED" {
            if purchased.id == "catalyst" {
                // The Catalyst Tracks: playable immediately, no cycle.
                purchased.purchaseState = "UNLOCKED_FOR_PLAYBACK"
            } else {
                purchased.purchaseState = purchased.completedDays >= purchased.totalDays
                    ? "UNLOCKED_FOR_PLAYBACK"
                    : "ACTIVE_IN_PROGRESS"
            }
        }

        // Progress saved on another phone comes back only now, after the
        // App Store has confirmed ownership — never from the record alone.
        ProgressBackup.applyConfirmedOwnership(of: purchased, among: journeys, snapshot: ProgressBackup.load())

        if isNewPurchase && purchased.id != "catalyst" {
            for journey in journeys {
                journey.isActive = journey.id == journeyId
            }
        }

        try? context.save()
        ProgressBackup.save(context: context, reason: "ownership confirmed")
        if isNewPurchase {
            Task { await DeliveryManager.shared.download(journeyId: journeyId) }
        } else {
            Task { await DeliveryManager.shared.refresh(ownedJourneyIds: [journeyId]) }
        }
        UpTimeLog.store.notice("[STORE] entitlement applied: \(productID, privacy: .public) → \(journeyId, privacy: .public) state=\(purchased.purchaseState, privacy: .public) newPurchase=\(isNewPurchase, privacy: .public)")
    }

    // MARK: - Verification helper

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Helpers

    func product(for journeyId: String) -> Product? {
        guard let productId = Self.catalog.currentProductId(forJourneyId: journeyId) else { return nil }
        return products.first(where: { $0.id == productId })
    }

    func isPurchased(_ journeyId: String) -> Bool {
        purchasedProductIDs.contains { Self.catalog.journeyId(forOwnedProductId: $0) == journeyId }
    }
}

// MARK: - StoreError

enum StoreError: Error {
    case failedVerification
}
