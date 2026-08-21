import FinanceKit
import Foundation

/// The single place FinanceKit's transaction type is translated into the
/// framework-free `WalletImportCandidate`. Shared by the manual picker
/// (GH #55, Tier 1) and automatic sync (Tier 2) so both import identically —
/// same payee normalization, same signing, same cleared rule.
enum FinanceKitBridge {

    /// - Returns: `nil` for transactions `WalletImportMapper` rejects
    ///   (rejected authorizations, amounts that don't fit integer cents).
    static func candidate(from transaction: FinanceKit.Transaction) -> WalletImportCandidate? {
        WalletImportMapper.candidate(
            id: transaction.id,
            amount: transaction.transactionAmount.amount,
            isCredit: transaction.creditDebitIndicator == .credit,
            merchantName: transaction.merchantName,
            transactionDescription: transaction.transactionDescription,
            status: status(from: transaction.status),
            date: transaction.transactionDate
        )
    }

    static func status(from status: FinanceKit.TransactionStatus) -> WalletImportMapper.Status {
        switch status {
        case .authorized: .authorized
        case .memo: .memo
        case .pending: .pending
        case .booked: .booked
        case .rejected: .rejected
        @unknown default: .booked
        }
    }
}
