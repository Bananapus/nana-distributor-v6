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
| P1 | Split funding trust mismatch | `processSplitWith` expects an ERC-20 allowance and pulls tokens via `transferFrom`. | Restrict callers and test the allowance flow. |

## 1. Trust Assumptions

- **`JBDirectory` is trusted.**
- **Stake sources are trusted.**
- **Deployment parameters must be sane.**

## 2. Economic Risks

- **Round snapshots are write-once per (hook, token, round).** A zero balance at first-snapshot time is a valid snapshot value, not a signal to re-snapshot. Tracked via an explicit init flag so mid-round deposits cannot leak into the current round's allocation.
- **Unclaimed value stays in the pool.**
- **Partial-round claims are linear, not cliff-based.**
- **Forfeited 721 rewards are recycled, not burned.**
- **Undelegated `IVotes` balances can dilute participation.**

## 3. Access Control And Caller Risks

- **Vesting is permissionless.**
- **Claim authority differs by distributor type.**
- **721 claim batches are brittle to invalid token IDs.**
- **Forfeiture release is effectively 721-only.**
- **Split-hook entry is tightly gated.**

## 4. DoS And Liveness Risks

- **Zero stake reverts vesting.**
- **Zero distributable balance reverts vesting.** The `beginVesting` call reverts with `JBDistributor_NothingToDistribute` if the distributable balance for a token is zero.
- **Bad constructor parameters can brick the instance.**
- **Resolver or token callback failures can block collection.**

## 5. Integration Risks

- **Split funding relies on a single allowance-based flow.**
- **Fee-on-transfer handling uses balance-delta accounting.** The `transferFrom` path measures `balanceAfter - balanceBefore` to credit the actual received amount.
- **721 stake weights depend on checkpointed voting power at round start.** The `CHECKPOINTS()` module must be deployed and delegates must be set before the round snapshot block, or stakers receive zero weight.
- **721 vesting and claiming treat burned tokens differently.**
- **Checkpoint availability matters for both `IVotes` token distributors and 721 distributors.**
- **Token distributor rejects token IDs with non-zero upper bits** (above 160) to prevent aliasing to the same staker address.

## 6. Invariants To Verify

- `totalVestingAmountOf <= _balanceOf`
- collections plus remaining vesting plus future distributable balance never exceed tracked funded balance
- round snapshots stay stable within a round once initialized, including zero-balance ones (write-once via the init flag)
- `latestVestedIndexOf` advances contiguously
- burned NFTs are excluded from 721 stake (via zero checkpointed votes) and only recycled through the explicit forfeiture path
- only the encoded address can collect from the token distributor

## 7. Accepted Behaviors

### 7.1 Anyone can trigger a round snapshot

`poke()`, `beginVesting`, and `collectVestedRewards` all call `_ensureSnapshotBlock`, which writes `roundSnapshotBlock[round] = block.number - 1` on first interaction. This is permissionless by design — keepers or frontends can call `poke()` early in a round to lock the snapshot block before any claims occur.

The trade-off: the first caller chooses *when* in the round the snapshot is anchored, so any legitimate stake changes that occur later in the same round are excluded from that round's reward math. An adversary who pokes early can therefore freeze the round's stake universe before later participants act. `_ensureSnapshotBlock` also eagerly pre-fills `round + 1` from the same call, which prevents a separate first-caller race on the next round but anchors `round + 1` at a block in `round`'s timeframe.

Operators should treat keeper-driven `poke()` at well-known times as part of the deployment runbook. Round rewards are mis-allocated only across the within-round delta of legitimate stake changes, not across the entire reward pool.

### 7.2 Rewards can remain undistributed when stake is missing

If some potential participants have zero effective stake for a round, the corresponding value stays in the distributor for future rounds.

### 7.3 721 and `IVotes` variants intentionally differ

They share the vesting engine but not the same ownership model.

### 7.4 Distribution eligibility requires enrollment

`JB721Checkpoints.ownerOfAt` returns `address(0)` for tokens that have never been enrolled or transferred. Unenrolled tokens are ineligible for snapshot-based distribution. Token holders enroll by calling `delegate(address delegatee, uint256[] calldata tokenIds)`, which writes per-token owner checkpoints. This keeps mint gas low — only users who want to participate in distribution pay the checkpoint storage cost. Transfers write checkpoints via `onTransfer`, so transferred tokens are eligible without explicit enrollment.
