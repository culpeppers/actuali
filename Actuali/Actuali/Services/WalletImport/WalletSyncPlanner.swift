import Foundation

/// One Actual account's worth of Wallet transactions, ready to import.
struct WalletSyncBatch: Equatable {
    let accountId: String
    let candidates: [WalletImportCandidate]
}

/// The framework-free decisions behind automatic Wallet sync (GH #55, Tier 2):
/// how far back to ask FinanceKit for, and which Actual account each Wallet
/// account's transactions land in. Kept clear of FinanceKit so it stays
/// unit-testable — the bridge lives in `WalletSyncService`.
enum WalletSyncPlanner {

    /// Days of already-synced history to re-request on every pass. A Wallet
    /// transaction is first published as `.pending` and re-published once it
    /// books — often at a different amount — so the recent window has to be
    /// re-read for those updates to arrive at all. Re-reading costs nothing:
    /// `BudgetStore.importWalletTransactions` dedups on `financial_id`.
    static let overlapDays = 7

    /// How far the first pass reaches back, when there is no last-sync date.
    /// Without a cap, mapping an account would pull FinanceKit's entire
    /// history into a budget that likely already has most of it.
    static let initialBackfillDays = 30

    /// The `transactionDate` floor for the next FinanceKit query.
    ///
    /// `min(lastSync, now)` guards a clock that moved backwards (or a
    /// timestamp restored from another device): a last-sync date in the
    /// future must never push the window past today and skip transactions.
    static func since(lastSync: Date?, now: Date, calendar: Calendar = .current) -> Date {
        let anchor = min(lastSync ?? now, now)
        let days = lastSync == nil ? initialBackfillDays : overlapDays
        return calendar.date(byAdding: .day, value: -days, to: anchor) ?? anchor
    }

    /// Turn FinanceKit's per-Wallet-account candidates into import batches.
    ///
    /// - Parameters:
    ///   - grouped: candidates keyed by Wallet (FinanceKit) account id.
    ///   - mappings: Wallet account id -> Actual account id.
    ///   - openAccountIds: accounts that still exist and are open.
    ///
    /// Unmapped Wallet accounts are skipped, and so are mappings whose Actual
    /// account has since been deleted or closed — sync must never invent a
    /// destination. Two Wallet accounts mapped to the same Actual account
    /// merge into one batch. Batches come back sorted by account id, and each
    /// batch's candidates by date, so a pass imports in a stable order.
    static func plan(
        grouped: [String: [WalletImportCandidate]],
        mappings: [String: String],
        openAccountIds: Set<String>
    ) -> [WalletSyncBatch] {
        var byAccount: [String: [WalletImportCandidate]] = [:]
        for (walletAccountId, candidates) in grouped {
            guard !candidates.isEmpty,
                  let accountId = mappings[walletAccountId],
                  openAccountIds.contains(accountId) else { continue }
            byAccount[accountId, default: []].append(contentsOf: candidates)
        }
        return byAccount
            .sorted { $0.key < $1.key }
            .map { accountId, candidates in
                WalletSyncBatch(
                    accountId: accountId,
                    candidates: candidates.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
                )
            }
    }
}
