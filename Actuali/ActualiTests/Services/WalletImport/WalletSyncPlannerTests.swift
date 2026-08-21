import Foundation
import Testing
@testable import Actuali

struct WalletSyncPlannerTests {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func candidate(
        id: String = UUID().uuidString.lowercased(),
        amountCents: Int = -820,
        payeeName: String = "Blue Bottle",
        date: Date = Date(timeIntervalSince1970: 1_750_000_000),
        cleared: Bool = true
    ) -> WalletImportCandidate {
        WalletImportCandidate(
            id: id,
            amountCents: amountCents,
            payeeName: payeeName,
            date: date,
            cleared: cleared
        )
    }

    private func days(_ count: Int, before date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -count, to: date)!
    }

    // MARK: - since

    @Test func firstPassBacksOffTheInitialBackfill() {
        let since = WalletSyncPlanner.since(lastSync: nil, now: now)
        #expect(since == days(WalletSyncPlanner.initialBackfillDays, before: now))
    }

    @Test func laterPassReReadsTheOverlapWindow() {
        let lastSync = days(2, before: now)
        let since = WalletSyncPlanner.since(lastSync: lastSync, now: now)
        #expect(since == days(WalletSyncPlanner.overlapDays, before: lastSync))
    }

    @Test func longGapReachesBackToTheLastSync() {
        // A budget untouched for months must still pull the whole gap — the
        // initial backfill cap applies only when there is no last-sync date.
        let lastSync = days(200, before: now)
        let since = WalletSyncPlanner.since(lastSync: lastSync, now: now)
        #expect(since == days(WalletSyncPlanner.overlapDays, before: lastSync))
        #expect(since < days(WalletSyncPlanner.initialBackfillDays, before: now))
    }

    @Test func futureLastSyncIsClampedToNow() {
        // A clock that moved backwards, or a stamp restored from another
        // device, must never push the window past today.
        let since = WalletSyncPlanner.since(lastSync: now.addingTimeInterval(86_400 * 5), now: now)
        #expect(since == days(WalletSyncPlanner.overlapDays, before: now))
    }

    // MARK: - plan

    @Test func mappedWalletAccountBecomesABatch() {
        let batches = WalletSyncPlanner.plan(
            grouped: ["wallet-1": [candidate(id: "a")]],
            mappings: ["wallet-1": "acct-1"],
            openAccountIds: ["acct-1"]
        )
        #expect(batches == [WalletSyncBatch(accountId: "acct-1", candidates: [candidate(id: "a")])])
    }

    @Test func unmappedWalletAccountIsSkipped() {
        let batches = WalletSyncPlanner.plan(
            grouped: ["wallet-1": [candidate()], "wallet-2": [candidate()]],
            mappings: ["wallet-1": "acct-1"],
            openAccountIds: ["acct-1"]
        )
        #expect(batches.map(\.accountId) == ["acct-1"])
    }

    @Test func mappingToAClosedOrDeletedAccountIsSkipped() {
        let batches = WalletSyncPlanner.plan(
            grouped: ["wallet-1": [candidate()]],
            mappings: ["wallet-1": "acct-closed"],
            openAccountIds: ["acct-1"]
        )
        #expect(batches.isEmpty)
    }

    @Test func twoWalletAccountsMappedToOneAccountMerge() {
        let older = candidate(id: "a", date: days(2, before: now))
        let newer = candidate(id: "b", date: now)
        let batches = WalletSyncPlanner.plan(
            grouped: ["wallet-1": [newer], "wallet-2": [older]],
            mappings: ["wallet-1": "acct-1", "wallet-2": "acct-1"],
            openAccountIds: ["acct-1"]
        )
        #expect(batches.count == 1)
        #expect(batches.first?.candidates.map(\.id) == ["a", "b"])
    }

    @Test func batchesAreOrderedByAccountThenDate() {
        let batches = WalletSyncPlanner.plan(
            grouped: [
                "wallet-2": [candidate(id: "b", date: now)],
                "wallet-1": [
                    candidate(id: "later", date: now),
                    candidate(id: "earlier", date: days(1, before: now))
                ]
            ],
            mappings: ["wallet-1": "acct-b", "wallet-2": "acct-a"],
            openAccountIds: ["acct-a", "acct-b"]
        )
        #expect(batches.map(\.accountId) == ["acct-a", "acct-b"])
        #expect(batches.last?.candidates.map(\.id) == ["earlier", "later"])
    }

    // MARK: - Toast copy

    @MainActor
    @Test func walletSyncNoticePluralizes() {
        #expect(BudgetStore.walletSyncNoticeText(count: 1) == "Imported 1 Wallet transaction")
        #expect(BudgetStore.walletSyncNoticeText(count: 2) == "Imported 2 Wallet transactions")
    }

    @Test func emptyCandidateListProducesNoBatch() {
        let batches = WalletSyncPlanner.plan(
            grouped: ["wallet-1": []],
            mappings: ["wallet-1": "acct-1"],
            openAccountIds: ["acct-1"]
        )
        #expect(batches.isEmpty)
    }
}
