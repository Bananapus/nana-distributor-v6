# Distributor Risk Register

This file covers the shared vesting engine in `JBDistributor` and the two concrete payout-split receivers, `JB721Distributor` and `JBTokenDistributor`.

## How To Use This File

- Read `Priority risks` first. Those are the failure modes with the highest payout-integrity impact.
- Treat the shared `JBDistributor` logic as the economic core.
- Use `Invariants to verify` as the minimum test envelope before routing live splits through a distributor.

## Priority Risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Wrong stake snapshot or stale stake source | A bad stake reading misallocates rewards for an entire round. | Snapshot review, invariants, and careful integration with the chosen hook or `IVotes` token. |
| P1 | Zero-stake or bad-parameter deployment | Bad constructor inputs or zero total stake can make core flows revert. | Deployment-time validation and operator runbooks. |
| P1 | Split funding trust mismatch | `processSplitWith` expects exact native value or an ERC-20 allowance and pulls tokens via `transferFrom`. | Restrict callers and test native conservation plus the allowance flow. |
| P1 | Reward-token callback accounting | ERC-20 reward tokens are arbitrary contracts and can call back during `transferFrom`. | Transiently block distributor reward-accounting mutations while an inbound ERC-20 balance delta is being measured. |

## 1. Trust Assumptions

- **`JBDirectory` is trusted.**
- **Stake sources are trusted.**
- **Deployment parameters must be sane.**

## 2. Economic Risks

- **Round snapshots are write-once per (hook, token, round).** A zero balance at first-snapshot time is a valid snapshot value, not a signal to re-snapshot. The 721 distributor tracks this with an explicit init flag so mid-round deposits cannot leak into the current round's allocation. The token distributor assigns accepted funding directly to the funding round.
- **Unclaimed value differs by distributor.** In the 721 distributor, unclaimed distributable balance can remain available for later rounds. In the token distributor, funded reward rounds are reserved for historical stakers and are not reallocated merely because a staker claims late.
- **Partial-round claims are linear, not cliff-based.**
- **Forfeited 721 rewards are recycled, not burned.**
- **Undelegated `IVotes` balances can dilute participation.**
- **721 owner voting budgets are spent only by nonzero allocations.** If a token's pro-rata reward rounds to zero, it
  must not consume the owner's per-round voting cap.

## 3. Access Control And Caller Risks

- **Vesting authority differs by distributor.** The 721 distributor permits third-party vesting calls. The token distributor only lets the encoded staker address start its own vesting clock.
- **Claim authority differs by distributor type.**
- **721 claim batches are brittle to invalid token IDs.**
- **Forfeiture release is effectively 721-only.**
- **Split-hook entry is tightly gated.**

## 4. DoS And Liveness Risks

- **Zero stake reverts vesting.**
- **Zero distributable balance reverts 721/shared vesting.** The shared `beginVesting` flow reverts with `JBDistributor_NothingToDistribute` if the distributable balance for a token is zero. Token-distributor historical claims can be no-ops when no past reward rounds are claimable.
- **Bad constructor parameters can brick the instance.**
- **Resolver or token callback failures can block collection.**

## 5. Integration Risks

- **Split funding relies on a single allowance-based flow.**
- **Native split funding is exact.** If `context.token == NATIVE_TOKEN`, `msg.value` must equal `context.amount`.
  Underpaying and overpaying both revert so terminal context accounting cannot drift from actual native value delivered.
  ERC-20 split contexts must send no native value.
- **Fee-on-transfer handling uses balance-delta accounting.** The `transferFrom` path measures `balanceAfter - balanceBefore` to credit the actual received amount.
- **Reward-token callbacks fail closed during funding.** While `fund` or `processSplitWith` is measuring an inbound
  ERC-20 balance delta, reentrant `fund`, `beginVesting`, `collectVestedRewards`, and `releaseForfeitedRewards` calls
  revert. This prevents both over-crediting from nested funding and under-crediting from same-token collection netting
  against the inbound transfer.
- **721 stake weights depend on checkpointed voting power at round start.** The `CHECKPOINTS()` module must be deployed and delegates must be set before the round snapshot block, or stakers receive zero weight.
- **721 vesting and claiming treat burned tokens differently.**
- **Checkpoint availability matters for both `IVotes` token distributors and 721 distributors.**
- **Token distributor rejects token IDs with non-zero upper bits** (above 160) to prevent aliasing to the same staker address.
- **Token distributor rewards follow delegated voting power.** For `IVotes` hooks, the encoded claimant address is the
  delegate/account whose `getPastVotes` are used. This may differ from underlying token ownership if holders delegate
  to someone else.
- **Token distributor hooks must be IVotes-compatible at funding time.** Funding records the current reward round's
  `getPastTotalSupply` snapshot, so arbitrary non-IVotes hook addresses are not valid token-distributor hooks.
- **Unaccounted direct sends are outside the reward ledger.** Plain ETH sent to `receive()` and direct ERC-20 transfers
  that bypass `fund`/`processSplitWith` are not credited into `_balanceOf`. Rebasing or otherwise balance-mutating
  tokens can also desynchronize actual token balances from the distributor's local accounting.

## 6. Invariants To Verify

- `totalVestingAmountOf <= _balanceOf`
- collections plus remaining vesting plus future distributable balance never exceed tracked funded balance
- round snapshots stay stable within a round once initialized, including zero-balance ones (write-once via the init flag)
- `latestVestedIndexOf` advances contiguously
- burned NFTs are excluded from 721 stake (via zero checkpointed votes) and only recycled through the explicit forfeiture path
- only the encoded address can begin vesting or collect from the token distributor
- native split-hook credits equal the native value actually received, and ERC-20 split-hook credits are measured by
  token balance delta with no accompanying `msg.value`
- ERC-20 funding balance-delta windows cannot be reentered to mutate reward accounting
- 721 consumed-vote caps only increase for token IDs that create a nonzero vesting entry

## 7. Accepted Behaviors

### 7.1 Anyone can trigger a round snapshot

`poke()` and the shared 721 vesting flow call `_ensureSnapshotBlock`, which writes `roundSnapshotBlock[round] = block.number - 1` on first interaction. Token-distributor funding records only the current round's snapshot block. Keepers or frontends can call `poke()` early in a round to lock the current and next snapshot block before funding or claims occur.

The trade-off: the first caller chooses *when* in the round the snapshot is anchored, so any legitimate stake changes that occur later in the same round are excluded from that round's reward math. An adversary who pokes early can therefore freeze the round's stake universe before later participants act. `_ensureSnapshotBlock` also eagerly pre-fills `round + 1` from the same call, which prevents a separate first-caller race on the next round but anchors `round + 1` at a block in `round`'s timeframe.

Operators should treat keeper-driven `poke()` at well-known times as part of the deployment runbook. Round rewards are mis-allocated only across the within-round delta of legitimate stake changes, not across the entire reward pool.

In the token distributor, current-round funding is assigned to the current reward round but cannot be claimed until a later round. A token staker claiming in round `N` only materializes rewards through round `N - 1`, and all materialized rewards start vesting at round `N`.

### 7.2 Rewards can remain undistributed when stake is missing

If token-distributor participants have zero effective stake for a funded reward round, their share is not redirected to later claimants. It remains in the distributor balance unless a claimant with historical voting power for that round materializes it. For 721 distributions, unvested or forfeited value can still return to the distributable pool under the 721-specific rules.

### 7.3 721 and `IVotes` variants intentionally differ

They share the vesting engine but not the same ownership model.

### 7.4 Distribution eligibility requires enrollment

`JB721Checkpoints.ownerOfAt` returns `address(0)` for tokens that have never been enrolled or transferred. Unenrolled tokens are ineligible for snapshot-based distribution. Token holders enroll by calling `delegate(address delegatee, uint256[] calldata tokenIds)`, which writes per-token owner checkpoints. This keeps mint gas low — only users who want to participate in distribution pay the checkpoint storage cost. Transfers write checkpoints via `onTransfer`, so transferred tokens are eligible without explicit enrollment.

### 7.5 Burned-token forfeiture follows the vesting curve

`releaseForfeitedRewards()` does not immediately free the full nominal amount of every burned token's vesting entry. It
uses the same linear unlock math as collection, with `ownerClaim = false`, so only the currently unlocked portion is
removed from `totalVestingAmountOf` and returned to the future distributable pool. Still-locked forfeited portions stay
accounted as vesting until a later forfeiture call unlocks them.
