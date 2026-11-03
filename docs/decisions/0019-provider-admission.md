# ADR-0019: Provider admission precedes live checkout

- Status: Accepted
- Date: 2026-10-25

## Context

Commerce's Pancake adapter proves protocol conformance against committed
fixtures, and the runbook's sandbox drill exists for the same reason: a
passing fixture suite establishes neither merchant eligibility, nor the
payment methods a buyer will actually be offered, nor the net economics
of settlement. Provider marketing pages answer none of those questions.
Presenting a checkout that cannot be paid — or one that reprices,
converts currency, or splits orders to evade a provider limit — is a
product failure, not a configuration detail.

## Decision

No provider adapter may present a live checkout for an Offer until the
provider carries a complete admission record, each entry backed by
approved evidence rather than inference:

1. **Approved scope.** The merchant account entity, the product
   category the approval covers, and the environments (test/live) it
   names.
2. **Capability matrix.** Payment method × currency × transaction type
   (one-time, recurring) × amount bounds, read from the provider's
   current public contract against the approved account. Merchant-side
   payout support never implies buyer-side payment support; every cell
   starts unknown and stays unknown without evidence.
3. **Verified contract paths.** The exact checkout-creation and active
   order-read endpoints the adapter will call, confirmed against the
   approved account, not the documentation alone.
4. **Cost stages.** Transaction fee, settlement/payout cost, FX, and
   reserves recorded as separate stages: a succeeded payment, a settled
   balance, and money in the bank account are three different facts.
5. **Refusal behavior.** Offers outside the admitted matrix are
   rejected before a checkout is presented; provider eligibility
   errors surface typed and unmodified. No silent repricing, currency
   conversion, or order splitting; no implying recurring support a
   method does not have.

The operator can encode the reviewed constraints in the private strict-JSON
`commerce/admission` manifest and must retain the supporting approval and
cost evidence outside Git. This enforces exact merchant/environment/Offer
price and pre-checkout refusal; a syntactically complete manifest is still
**not independent proof of merchant authorization**. The Alipay operator
example refuses to mint a binding unless the manifest permits it.

The filled record lives with the deployment that operates the adapter —
it names real accounts and therefore never enters this repository. This
repository records the discipline, the template, and the admission
status per provider. Admission is per provider and per approved scope:
one approved channel never admits another.

## Status

- **Pancake: not admitted.** No approved merchant account exists. The
  adapter's protocol conformance is fixture-proven only
  (`commerce-test/pancake-test.rkt`, `commerce-test/reconcile-test.rkt`);
  the runbook's live sandbox drill is the next evidence step, and its
  capture still proves the protocol, not eligibility.
- **ZPAY: not admitted.** Admission would be a separate decision
  requiring an approved account and a demonstrated product gap.
  Commerce does not model ZPAY as recurring unless the live provider
  contract gains that capability.

## Consequences

- The gap between "fixtures pass" and "may take a payment" is explicit
  and auditable instead of implied.
- Admission gates only the checkout edge. The durable core never
  issues twice regardless of channel discipline: replays converge on
  the same bytes and one renewal intent is keyed per new paid-through
  window (`commerce-test/subscription-test.rkt`), so a replayed payment
  cannot extend a window twice.
- Products keep login/recovery with the product owner and Permit
  verification at the verifier; admission never creates a universal
  licensing account (see `docs/family-integration.md`).
- When an account is approved, the record is filled from that approval,
  the capability matrix turns concrete cells, and only then does
  adapter work against the live contract begin.
