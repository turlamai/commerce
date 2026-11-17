# ADR-0026 — Order-scoped prepaid calendar periods

Status: implementation. Scope: opt-in `use-duration-months` policies only.

Each independently authenticated one-time paid order contributes the immutable
interval [paid-at, paid-at + N UTC calendar months). A full refund removes only
that order; no window is shifted, stacked or restarted by notification time.
The accepted journal is the durable order ledger. Rebuilding periods from all
scoped facts handles duplicates, refund-before-payment and delayed older orders.
The maximum remaining end becomes the complete signed snapshot's use expiry.
Products own checkout eligibility and quota selection; concurrent overlapping
payments never earn stacked time or multiplied monthly quota by accident.

The issuer re-authenticates EVERY contributing journal row, not only the outbox
trigger. Canonical amount, subject, Offer and order identity remain immutable.
Any invalid/conflicting/recurring fact refuses the whole reconciliation. Before
recording a signed revision, SQLite compares the complete scoped journal
snapshot in the same immediate transaction. New facts during signing cause a
retry, not publication of stale rights. Existing revision/lease guards remain.

Schema v9 adds an append-only prepaid checkpoint per issued revision: the
highest covered journal sequence. It records coverage, not payment authority.
Refunds covered by this signed reconciliation are resolved even when another
order remains paid, or a refund arrived before payment and emitted no outbox.
Uncovered refunds still deny hosted proof until reconciliation commits.
Revision action describes resulting rights (grant or withdrawal); outbox action
continues to describe the triggering payment/refund. An expired paid order
remains an expired grant; no remaining paid order produces a withdrawal successor. If no lineage has yet
been published, revision zero is an immediately expired grant (the existing
schema invariant requires an initial grant), never usable hosted rights.

No Permit schema changes or automatic debits. Fixed/perpetual policies retain
existing behavior. Writable open migrates v8 to v9; read-only open refuses old
schemas. Back up before migration; rollback needs a pre-migration database copy.
Fixture validation is distinct from deployed official sandbox payment evidence.

A calendar checkpoint also identifies the service's half-open time contract:
hosted proof excludes the exact expiry second, while the underlying Permit
protocol retains its inclusive final-instant semantics for other products.
Full-refund duplicate deliveries for an already reconciled order do not reopen
a pending state. Signature checks for initial prepaid Alipay grants bind the
signed gmt_payment and merchant identity to the stored canonical evidence.

A changed scoped journal or concurrently advanced lineage is a transient retry
(default 30 seconds), not an hour-long operator backoff. The completion
transaction compares the proposed signed revision with the next durable revision
as well as the scoped records. No operator redrive is needed for these normal
concurrency races.
