// Flip POSITIVE rows for PRINCIPAL and ACCRUED INTEREST RECEIVABLE: CREDIT -> DEBIT
db.SubledgerMapping.updateMany(
  {
    sign: "POSITIVE",
    accountSubType: { $in: ["PRINCIPAL", "ACCRUED INTEREST RECEIVABLE"] },
    entryType: "CREDIT"
  },
  { $set: { entryType: "DEBIT" } }
);

// Flip NEGATIVE rows for PRINCIPAL and ACCRUED INTEREST RECEIVABLE: DEBIT -> CREDIT
db.SubledgerMapping.updateMany(
  {
    sign: "NEGATIVE",
    accountSubType: { $in: ["PRINCIPAL", "ACCRUED INTEREST RECEIVABLE"] },
    entryType: "DEBIT"
  },
  { $set: { entryType: "CREDIT" } }
);