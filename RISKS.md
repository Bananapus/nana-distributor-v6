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

- **Round snapshot timing has a zero-balance edge case.**
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
- non-zero round snapshots stay stable within a round
- `latestVestedIndexOf` advances contiguously
- burned NFTs are excluded from 721 stake (via zero checkpointed votes) and only recycled through the explicit forfeiture path
- only the encoded address can collect from the token distributor

## 7. Accepted Behaviors

### 7.1 Anyone can trigger a round snapshot

This improves liveness, but it also means operators do not fully control the exact block when a round is crystallized.

### 7.2 Rewards can remain undistributed when stake is missing

If some potential participants have zero effective stake for a round, the corresponding value stays in the distributor for future rounds.

### 7.3 721 and `IVotes` variants intentionally differ

They share the vesting engine but not the same ownership model.
