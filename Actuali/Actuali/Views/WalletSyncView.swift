import SwiftUI
import UIKit

/// Set up ongoing Wallet sync: grant access once, map each Wallet card to an
/// Actual account, and new transactions arrive on their own (GH #55, Tier 2).
///
/// Unlike the one-off picker in `WalletImportView`, this needs Apple's managed
/// FinanceKit entitlement. On a build without it the authorization request
/// fails, which surfaces here as an error rather than as a broken toggle.
struct WalletSyncView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    @State private var authorization: WalletAuthorization = .notDetermined
    @State private var walletAccounts: [WalletAccount] = []
    @State private var isLoading = true
    @State private var isSyncing = false
    @State private var syncResult: String?
    @State private var errorMessage: String?

    private var openAccounts: [Account] {
        budgetStore.accounts.filter { !$0.closed }
    }

    /// Mappings that point at a card Wallet still offers. A mapping left over
    /// from a card that has since been removed can never sync, so it must not
    /// make the screen look ready. Zero while the card list is still loading,
    /// which is why every use of it is guarded on `isLoading`.
    private var mappedCount: Int {
        let walletIds = Set(walletAccounts.map(\.id))
        return budgetStore.walletAccountMappings.keys.filter { walletIds.contains($0) }.count
    }

    var body: some View {
        Form {
            if !WalletSyncService.isSupported {
                unsupportedSection
            } else {
                switch authorization {
                case .authorized:
                    automaticSection
                    accountsSection
                    syncNowSection
                case .notDetermined:
                    requestAccessSection
                case .denied:
                    deniedSection
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Wallet Sync")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await reload()
        }
    }

    private var unsupportedSection: some View {
        Section {
            Text("Wallet transactions aren't available on this device. Apple Card, Apple Cash and Savings are required, and are currently US-only.")
                .foregroundStyle(.secondary)
        }
    }

    private var requestAccessSection: some View {
        Section {
            Button("Allow Wallet Access") {
                Task { await requestAccess() }
            }
            .disabled(isLoading)
        } header: {
            Text("Wallet Access")
        } footer: {
            Text("Actuali reads transactions from the Wallet cards you choose and adds them to your budget. It never writes to Wallet, and nothing leaves your device except the transactions your Actual server already syncs.")
        }
    }

    private var deniedSection: some View {
        Section {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("Wallet Access")
        } footer: {
            Text("Wallet access is turned off for Actuali. Turn it back on under Privacy & Security in the Settings app to sync automatically. You can still import transactions by hand from the Automations screen.")
        }
    }

    private var automaticSection: some View {
        Section {
            Toggle("Sync Automatically", isOn: $budgetStore.automaticWalletSync)
        } footer: {
            if budgetStore.automaticWalletSync && !isLoading && mappedCount == 0 {
                Text("Nothing syncs yet — map at least one Wallet card to an account below.")
            } else {
                Text("New transactions from mapped cards are imported each time you open Actuali. Transactions already in the account are skipped, so nothing is imported twice.")
            }
        }
    }

    private var accountsSection: some View {
        Section {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if walletAccounts.isEmpty {
                Text("No Wallet accounts were shared with Actuali.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(walletAccounts) { walletAccount in
                    Picker(selection: binding(for: walletAccount)) {
                        Text("Don't Sync").tag(String?.none)
                        ForEach(openAccounts) { account in
                            Text(account.name).tag(Optional(account.id))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(walletAccount.displayName)
                            Text(walletAccount.institutionName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Cards")
        } footer: {
            Text("Each card imports into the account you pick here. Cards left on Don't Sync are ignored.")
        }
    }

    private var syncNowSection: some View {
        Section {
            Button {
                Task { await syncNow() }
            } label: {
                if isSyncing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Sync Now")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(isSyncing || isLoading || mappedCount == 0)

            if let syncResult {
                Label {
                    Text(syncResult)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            HStack {
                Text("Last Synced")
                Spacer()
                Text(lastSyncedText)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lastSyncedText: String {
        guard let date = budgetStore.lastWalletSyncDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// A card's destination account. Writing nil removes the mapping outright
    /// rather than storing an empty string, so `walletAccountMappings` only
    /// ever holds cards that actually sync.
    private func binding(for walletAccount: WalletAccount) -> Binding<String?> {
        Binding(
            get: { budgetStore.walletAccountMappings[walletAccount.id] },
            set: { newValue in
                var mappings = budgetStore.walletAccountMappings
                if let newValue {
                    mappings[walletAccount.id] = newValue
                } else {
                    mappings.removeValue(forKey: walletAccount.id)
                }
                budgetStore.walletAccountMappings = mappings
            }
        )
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        authorization = await budgetStore.walletAuthorizationStatus()
        guard authorization == .authorized else { return }
        do {
            walletAccounts = try await budgetStore.walletAccounts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func requestAccess() async {
        errorMessage = nil
        do {
            authorization = try await budgetStore.requestWalletAuthorization()
            if authorization == .authorized {
                await reload()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Result stays on this screen rather than going through the toast the
    /// automatic pass uses: the user is looking right at the button, and a
    /// pass that imported nothing is worth saying so here.
    private func syncNow() async {
        isSyncing = true
        defer { isSyncing = false }
        errorMessage = nil
        syncResult = nil
        do {
            let imported = try await budgetStore.syncWalletTransactions()
            syncResult = imported > 0
                ? BudgetStore.walletSyncNoticeText(count: imported)
                : "No new Wallet transactions"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        WalletSyncView()
            .environmentObject(BudgetStore.previewInstance())
    }
}
