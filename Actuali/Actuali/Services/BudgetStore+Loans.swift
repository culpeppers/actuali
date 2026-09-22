import Foundation

// MARK: - Pairing

extension BudgetStore {
    /// Pair the loan with a budget category, or unpair it with nil.
    ///
    /// Read-modify-write on the stored config rather than a field the caller
    /// assembles, so pairing from the account screen can't overwrite terms
    /// edited elsewhere in the meantime.
    func pairLoan(accountId: String, categoryId: String?) async {
        guard var config = loanConfigs[accountId] else { return }
        config.categoryId = categoryId
        await setLoan(accountId: accountId, config: config)
    }

    /// The category paired with a loan, if it still exists and is visible.
    /// A category deleted or hidden after pairing leaves the loan unpaired
    /// for display rather than naming something the user can't see.
    func pairedLoanCategory(for accountId: String) -> Category? {
        guard let categoryId = activeLoanConfig(for: accountId)?.categoryId else { return nil }
        return categoryGroups
            .flatMap(\.categories)
            .first { $0.id == categoryId && !$0.hidden }
    }
}

// MARK: - Recording a payment

extension BudgetStore {
    /// Post a loan payment as real transactions, the way YNAB splits one.
    ///
    /// Three rows rather than one, because a payment is three movements of
    /// money and flattening them loses the distinction the loan screens are
    /// built on:
    ///
    /// - the lender's interest charge, an outflow on the loan account
    /// - the escrow or fee charge, likewise, when the loan carries one
    /// - the payment itself, a transfer from the funding account, carrying
    ///   the paired category on its on-budget leg
    ///
    /// The loan account nets to the principal while the category sees the
    /// whole payment — which is exactly the split between YNAB's Overview and
    /// Activity tabs, and falls out of the double entry rather than needing a
    /// second set of numbers to maintain.
    ///
    /// `interest` and `escrow` are passed in rather than recomputed so the
    /// caller can correct them to what the lender actually charged, which the
    /// estimate won't always match.
    func recordLoanPayment(
        accountId: String,
        fromAccountId: String,
        payment: Int,
        interest: Int,
        escrow: Int,
        date: Int,
        notes: String?,
        cleared: Bool = true
    ) async throws {
        // Read once up front: the charges below suspend, and a sync landing
        // mid-flight shouldn't move the payment to a different category than
        // the one the sheet showed.
        let categoryId = loanConfigs[accountId]?.categoryId
        guard accountId != fromAccountId else {
            throw BudgetStoreError.transferAccountsMatch
        }
        guard payment > 0 else {
            throw BudgetStoreError.transferAmountNotPositive
        }

        // Charges first, payment last: the transfer's refresh is then the one
        // that settles the published state.
        if interest != 0 {
            try await postLoanCharge(
                accountId: accountId, amount: -interest, date: date,
                payeeName: String(localized: "Interest"), notes: notes, cleared: cleared
            )
        }
        if escrow != 0 {
            try await postLoanCharge(
                accountId: accountId, amount: -escrow, date: date,
                payeeName: String(localized: "Escrow"), notes: notes, cleared: cleared
            )
        }

        try await createTransfer(
            fromAccountId: fromAccountId,
            toAccountId: accountId,
            amountCents: payment,
            date: date,
            notes: notes,
            cleared: cleared,
            categoryId: categoryId
        )
    }

    /// One lender charge on the loan account. Off-budget, so it carries no
    /// category — `preserveCategory` keeps a rule from attaching one.
    private func postLoanCharge(
        accountId: String,
        amount: Int,
        date: Int,
        payeeName: String,
        notes: String?,
        cleared: Bool
    ) async throws {
        let payee = try await findOrCreatePayee(name: payeeName)
        _ = try await createTransaction(
            Transaction(
                id: UUID().uuidString,
                accountId: accountId,
                date: date,
                amount: amount,
                payeeId: payee.id,
                payeeName: payee.name,
                categoryId: nil,
                categoryName: nil,
                notes: notes,
                cleared: cleared,
                reconciled: false,
                transferId: nil,
                isParent: false,
                parentId: nil,
                tombstone: false,
                sortOrder: nil,
                importedPayee: nil
            ),
            preserveCategory: true
        )
    }
}
