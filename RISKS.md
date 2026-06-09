# Distributor Risk Register

This file covers the shared vesting engine in `JBDistributor` and the two concrete payout-split receivers, `JB721Distributor` and `JBTokenDistributor`.

## How to use this file

- Read `Priority risks` first. Those are the failure modes with the highest payout-integrity impact.
- Treat the shared `JBDistributor` logic as the economic core.
- Use `Invariants to verify` as the minimum test envelope before routing live splits through a distributor.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Wrong stake snapshot or stale stake source | A bad stake reading misallocates rewards for an entire round. | Snapshot review, invariants, and careful integration with the chosen hook or `IVotes` token. |
| P1 | Zero-stake or bad-parameter deployment | Bad constructor inputs can brick an instance; no eligible stake can leave reward rounds unclaimable until cleanup rules apply. | Deployment-time validation and operator runbooks. |
| P1 | Split funding trust mismatch | `processSplitWith` expects exact native value or an ERC-20 allowance and pulls tokens via `transferFrom`. | Restrict callers and test native conservation plus the allowance flow. |
| P1 | Expiry window misconfiguration | Too-short claim durations can make unclaimed rewards recyclable earlier than intended. | Deployment runbooks, UI warnings, and tests for deadline behavior. |
| P1 | Revnet loan custody mismatch | If the claimant receives the loan NFT, they can repay directly and bypass vesting. | The distributor owns loan NFTs, blocks collection while collateralized, and restores collateral only through `repayVestingLoan`. |
| P1 | Reward-token callback accounting | ERC-20 reward tokens are arbitrary contracts and can call back during `transferFrom`; native value transfers (e.g. the vesting-loan overpayment refund) can call back into the recipient. | Transiently block distributor reward-accounting mutations while an inbound ERC-20 balance delta is being measured. Settle a repaid vesting loan's state before refunding any native overpayment, so a re-entrant write-off cannot double-decrement the loaned-vesting inventory (checks-effects-interactions). |

## 1. Trust assumptions

- **`JBDirectory` is trusted.**
- **Stake sources are trusted.**
- **Deployment parameters must be sane.**

## 2. Economic risks

- **Reward-round snapshots are write-once per (hook, token, round).** Accepted funding is assigned to the current reward round and records that round's snapshot block plus total stake. Later funding in the same round accumulates into the same reward pot.
- **Late claims do not reallocate historical rewards.** Funded reward rounds are reserved for historical stakers or NFT owners and are not reassigned merely because someone claims late.
- **Expiring token rounds are active-voter rounds.** A nonzero immutable claim duration records the hook's
  `getPastTotalActiveVotes` at the funded round's snapshot block. Only addresses with snapshot `getPastVotes` share
  the pot during the claim window. Unclaimed rewards can be recycled into the current reward round after the deadline.
- **Claim duration is deployment-wide.** To keep per-round storage compact, one hook/token/round has one claim deadline. Funding calls do not accept caller-chosen deadlines.
- **Partial-round claims are linear, not cliff-based.**
- **Forfeited 721 rewards are recycled through the current round.** Burned-token forfeiture removes only the currently
  unlocked portion from the burned token's vesting obligation, then records that amount into the current reward round.
- **Revnet loans are a liquidity path, not a vesting bypass.** Borrowed vesting collateral is removed from active
  inventory and tracked as `totalLoanedVestingAmountOf`, but the vesting entries are not advanced or deleted. Repayment
  restores the collateral to the distributor, then the same original vesting schedule determines what can be collected.
  If Revnet liquidates the loan, anyone can write it off so the destroyed collateral is forfeited and the local
  collection lock is cleared. Distributors with `VESTING_ROUNDS == 0` reject vesting loans because there is no locked
  vesting period to finance.
- **Undelegated `IVotes` balances dilute only non-expiring token rounds.** Token distributors with
  `CLAIM_DURATION == 0` use `getPastTotalSupply` as the denominator. Token distributors with nonzero claim duration
  use `getPastTotalActiveVotes`, so undelegated balances do not share the active-voter pot.
- **721 owner voting budgets are spent only by nonzero allocations.** If a token's pro-rata reward rounds to zero, it
  must not consume the owner's per-round voting cap.

## 3. Access control and caller risks

- **Vesting authority differs by distributor.** The token distributor only lets the encoded staker address start its own vesting clock. The 721 distributor only lets the current NFT owner materialize and collect rewards for that token ID.
- **Claim authority differs by distributor type.**
- **721 claim batches are brittle to invalid token IDs.**
- **Forfeiture release is effectively 721-only.**
- **Split-hook entry is tightly gated.**

## 4. DoS and liveness risks

- **Zero stake creates no reward entries.**
- **Empty historical claims can be no-ops.** Token and 721 historical claims can succeed without creating a vesting entry when no past reward rounds are claimable or the claimant had zero eligible stake.
- **Bad constructor parameters can brick the instance.**
- **Resolver or token callback failures can block collection.**
- **Expired recycling is permissionless but deadline-gated.** Any caller can recycle eligible expired inventory after the
  configured deadline. Non-expired and non-expiring rounds cannot be recycled.
- **Loan-backed collection is intentionally locked while a loan is active.** If a token ID's vesting rewards are
  collateralized, collection for that token ID and reward token reverts until the distributor-owned loan is repaid or
  liquidated and written off.

## 5. Integration risks

- **Split funding relies on a single allowance-based flow.**
- **Native split funding is exact.** If `context.token == NATIVE_TOKEN`, `msg.value` must equal `context.amount`.
  Underpaying and overpaying both revert so terminal context accounting cannot drift from actual native value delivered.
  ERC-20 split contexts must send no native value.
- **Fee-on-transfer handling uses balance-delta accounting.** The `transferFrom` path measures `balanceAfter - balanceBefore` to credit the actual received amount.
- **Expiration is explicit at deployment.** Split funding and plain `fund` both use the same immutable duration. Deploy
  token distributors with `0` for the non-expiring total-supply path, or a nonzero duration for the active-voter
  active-total path.
- **Reward-token callbacks fail closed during funding.** While `fund` or `processSplitWith` is measuring an inbound
  ERC-20 balance delta, reentrant `fund`, `beginVesting`, `collectVestedRewards`, and `releaseForfeitedRewards` calls
  revert. This prevents both over-crediting from nested funding and under-crediting from same-token collection netting
  against the inbound transfer.
- **721 stake weights depend on checkpointed voting power at the funded round's snapshot block.** The `CHECKPOINTS()` module must be deployed and delegates must be set before the snapshot block, or stakers receive zero weight.
- **721 vesting and claiming treat burned tokens differently.**
- **Checkpoint availability matters for both `IVotes` token distributors and 721 distributors.**
- **Token distributor rejects token IDs with non-zero upper bits** (above 160) to prevent aliasing to the same staker address.
- **Token distributor rewards follow delegated voting power.** For `IVotes` hooks, the encoded claimant address is the
  delegate/account whose `getPastVotes` are used. This may differ from underlying token ownership if holders delegate
  to someone else.
- **Token distributor hooks must be IVotes-compatible.** Non-expiring token funding records the current reward round's
  `getPastTotalSupply` snapshot. Active-voter token funding records the current reward round's
  `getPastTotalActiveVotes` snapshot and claims use each claimant's `getPastVotes` snapshot. Arbitrary non-IVotes hook
  addresses are not valid token-distributor hooks.
- **721 distributor hooks must expose compatible checkpoint data at funding time.** Funding records the current reward
  round's `getPastTotalSupply` snapshot through the 721 hook's checkpoints module, so arbitrary addresses are not valid
  721 hooks.
- **Unaccounted direct sends are outside the reward ledger.** Plain ETH sent to `receive()` and direct ERC-20 transfers
  that bypass `fund`/`processSplitWith` are not credited into `_balanceOf`. Rebasing or otherwise balance-mutating
  tokens can also desynchronize actual token balances from the distributor's local accounting.
- **Revnet loan-backed vesting trusts the configured loans contract.** The distributor checks that the reward token is a
  REVOwner-owned revnet token, grants the loans contract burn permission at deployment, and verifies that repayment
  returns at least the borrowed collateral. It also relies on `loanOf(loanId).createdAt == 0` as the signal that a
  tracked loan was liquidated and can be written off.

## 6. Invariants to verify

- `totalVestingAmountOf - totalLoanedVestingAmountOf <= _balanceOf`
- `totalLoanedVestingAmountOf` is backed by distributor-owned loan NFTs and returns to normal inventory on repayment,
  or is removed from vesting inventory on liquidation write-off
- collections plus remaining vesting plus future distributable balance never exceed tracked funded balance
- round snapshots stay stable within a round once initialized, including zero-balance ones; active-voter token rounds
  seal `totalStake` from `getPastTotalActiveVotes` at the fixed snapshot block
- expired recycling settles eligible expired rounds and records the recycled amount into the current round without changing
  tracked balance
- `latestVestedIndexOf` advances contiguously
- burned NFTs are excluded from 721 stake (via zero checkpointed votes), and their historical forfeited rewards
  materialize and recycle only through the explicit forfeiture path
- only the encoded address can begin vesting or collect from the token distributor
- only live NFT IDs can begin vesting, and collection helpers must route to the current NFT owner unless the owner
  redirects rewards themselves
- native split-hook credits equal the native value actually received, and ERC-20 split-hook credits are measured by
  token balance delta with no accompanying `msg.value`
- ERC-20 funding balance-delta windows cannot be reentered to mutate reward accounting
- 721 consumed-vote caps only increase for token IDs that create a nonzero vesting entry
- late claim/recycle transactions recycle an expired token round (one past its `claimDeadline`) unconditionally — the
  unclaimed remainder is redistributed to the current round's active voters, and an individual late claim on an expired
  round returns zero. Rounds configured with `CLAIM_DURATION == 0` never expire and are therefore never recycled.

## 7. Accepted behaviors

### 7.1 Anyone can trigger a round snapshot

`poke()` calls `_ensureSnapshotBlock`, which writes `roundSnapshotBlock[round] = block.number - 1` on first interaction and eagerly records the next round. Token and 721 funding call `_ensureSnapshotBlockFor` for the current reward round. Keepers or frontends can call `poke()` early in a round to lock the current and next snapshot block before funding or claims occur.

The trade-off: the first caller chooses *when* in the round the snapshot is anchored, so any legitimate stake changes that occur later in the same round are excluded from that round's reward math. An adversary who pokes early can therefore freeze the round's stake universe before later participants act. `_ensureSnapshotBlock` also eagerly pre-fills `round + 1` from the same call, which prevents a separate first-caller race on the next round but anchors `round + 1` at a block in `round`'s timeframe.

Operators should treat keeper-driven `poke()` at well-known times as part of the deployment runbook. Round rewards are mis-allocated only across the within-round delta of legitimate stake changes, not across the entire reward pool.

In both concrete distributors, current-round funding is assigned to the current reward round but cannot be claimed until a later round. A claimant in round `N` only materializes rewards through round `N - 1`, and all materialized rewards start vesting at round `N`.

### 7.2 Expired unclaimed rewards are recyclable

Deployers can set a claim duration to attach a deadline to all funding paths. The window starts when the funded reward round first becomes claimable, not when the transfer lands. For token distributors, a nonzero duration uses the hook's active-vote total at funding. After the deadline, `recycleExpiredRewards` can be called by anyone to move unclaimed expired inventory into the current round.

This is intentionally different from late non-expiring claims. Non-expiring rounds remain reserved for historical stakers or NFT owners indefinitely. Active-voter token rounds trade total-supply dilution for an active-vote denominator and a deployer-configured claim window.

### 7.3 Rewards can remain undistributed when stake is missing

If participants have zero effective stake for a funded reward round, their share is not redirected to later claimants.
It remains in the distributor balance unless a claimant with historical voting power for that round materializes it. For
721 distributions, burned NFTs' unclaimed historical shares can be materialized through `releaseForfeitedRewards`, and
the unlocked forfeited value can return to the distributable pool under the 721-specific rules.

Deploy-config footgun — permanent strand under `CLAIM_DURATION == 0`: a round whose snapshot `totalStake` is zero
(realistic at a project's first funding, before any holder has delegated — active votes count only delegated units) can
never be claimed. If the distributor was deployed with `CLAIM_DURATION == 0`, that round also never expires, so
`recycleExpiredRewards` can never move it and the funded amount is stranded permanently. Mitigation: deploy with a
nonzero `CLAIM_DURATION` (so a no-stake round eventually expires and recycles to active voters), and/or ensure at least
one holder has self-delegated before the first round is funded.

### 7.4 721 and `IVotes` variants intentionally differ

They share the vesting engine but not the same ownership model.

### 7.5 Distribution eligibility requires enrollment

`JB721Checkpoints.ownerOfAt` returns `address(0)` for tokens that have never been enrolled or transferred. Unenrolled tokens are ineligible for snapshot-based distribution. Token holders enroll by calling `delegate(address delegatee, uint256[] calldata tokenIds)`, which writes per-token owner checkpoints. This keeps mint gas low — only users who want to participate in distribution pay the checkpoint storage cost. Transfers write checkpoints via `onTransfer`, so transferred tokens are eligible without explicit enrollment.

### 7.6 Burned-token forfeiture follows the vesting curve

`releaseForfeitedRewards()` does not immediately free the full nominal amount tied to every burned token. It first
materializes any unclaimed historical shares for the burned token IDs, then uses the same linear unlock math as
collection, with `ownerClaim = false`. Only the currently unlocked portion is removed from `totalVestingAmountOf` and
recycled into the current reward round. Still-locked forfeited portions stay accounted as vesting until a later
forfeiture call unlocks and recycles them.
