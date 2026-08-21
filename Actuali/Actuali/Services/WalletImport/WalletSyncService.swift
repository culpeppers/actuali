import FinanceKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "WalletSync")

/// A Wallet account reduced to what the mapping UI needs. Framework-free and
/// `Sendable` so it can cross from the actor to `@MainActor` state.
struct WalletAccount: Identifiable, Hashable, Sendable {
    /// FinanceKit account UUID, lowercased — the key mappings are stored under.
    let id: String
    let displayName: String
    let institutionName: String
}

/// Whether the user has granted Actuali ongoing read access to Wallet.
enum WalletAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

enum WalletSyncError: LocalizedError, Equatable {
    case unavailable
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Wallet transactions aren't available on this device. Apple Card, Apple Cash and Savings are required, and are currently US-only."
        case .notAuthorized:
            "Actuali doesn't have permission to read your Wallet transactions."
        }
    }
}

/// Ongoing read access to Wallet transactions for automatic sync
/// (GH #55, Tier 2).
///
/// Unlike the Tier 1 picker in `WalletImportView`, this path needs Apple's
/// managed `com.apple.developer.financekit` entitlement. Until Apple grants it
/// for the bundle id, `requestAuthorization()` and every read below fail — so
/// callers must surface an error as "not available here" rather than treat it
/// as a bug.
///
/// Reads only. Actuali never writes to Wallet, and nothing here leaves the
/// device except as ordinary transactions synced to the user's own server.
actor WalletSyncService {

    /// Whether this device has Wallet financial data at all. Same gate the
    /// Tier 1 picker uses; false hides every automatic-sync entry point.
    static var isSupported: Bool {
        FinanceStore.isDataAvailable(.financialData)
    }

    private let store = FinanceStore.shared

    func authorizationStatus() async throws -> WalletAuthorization {
        Self.authorization(from: try await store.authorizationStatus())
    }

    func requestAuthorization() async throws -> WalletAuthorization {
        Self.authorization(from: try await store.requestAuthorization())
    }

    /// Every Wallet account the user has authorized, for the mapping UI.
    func accounts() async throws -> [WalletAccount] {
        try await requireAuthorization()
        let accounts = try await store.accounts(query: AccountQuery())
        // Sorted here rather than by the query: it's a handful of cards, and
        // the display order is a UI concern, not something to ask Wallet for.
        return accounts
            .map {
                WalletAccount(
                    id: $0.id.uuidString.lowercased(),
                    displayName: $0.displayName,
                    institutionName: $0.institutionName
                )
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    /// Import candidates for everything on or after `since`, keyed by Wallet
    /// account id.
    ///
    /// The query is filtered by date only and grouped here rather than run
    /// once per mapped account: FinanceKit returns every authorized account in
    /// one pass, and which of them are mapped is `WalletSyncPlanner`'s call.
    func transactions(since: Date) async throws -> [String: [WalletImportCandidate]] {
        try await requireAuthorization()
        // No sort descriptor: WalletSyncPlanner orders each batch by date
        // anyway, and unsorted is one less thing for the query to do.
        let query = TransactionQuery(
            predicate: #Predicate<FinanceKit.Transaction> { $0.transactionDate >= since }
        )
        var grouped: [String: [WalletImportCandidate]] = [:]
        for transaction in try await store.transactions(query: query) {
            guard let candidate = FinanceKitBridge.candidate(from: transaction) else { continue }
            grouped[transaction.accountID.uuidString.lowercased(), default: []].append(candidate)
        }
        let total = grouped.values.reduce(0) { $0 + $1.count }
        logger.debug("Wallet sync read \(total) transaction(s) across \(grouped.count) account(s)")
        return grouped
    }

    private func requireAuthorization() async throws {
        guard Self.isSupported else { throw WalletSyncError.unavailable }
        guard try await authorizationStatus() == .authorized else {
            throw WalletSyncError.notAuthorized
        }
    }

    private static func authorization(from status: AuthorizationStatus) -> WalletAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .denied
        }
    }
}
