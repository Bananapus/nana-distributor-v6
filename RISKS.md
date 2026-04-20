# Distributor Risk Register

This file covers the shared vesting engine in `JBDistributor` and the two concrete payout-split receivers, `JB721Distributor` and `JBTokenDistributor`. The main risks are snapshot timing, stake-accounting correctness, and operational assumptions about who can trigger vesting and claims.

## How to use this file

- Read `Priority risks` first; those are the failure modes with the highest payout-integrity impact.
- Treat the shared `JBDistributor` logic as the economic core. The 721 and token variants mainly change stake measurement and claim authority.
- Use `Invariants to Verify` as the minimum test envelope before routing live splits through a distributor instance.

## Priority risks

| Priority | Risk | Why it matters | Primary controls |
|----------|------|----------------|------------------|
| P0 | Wrong stake snapshot or stale stake source | A bad `_totalStake` or `_tokenStake` reading misallocates rewards for an entire round. | Snapshot review, invariant tests, and careful integration with the chosen hook or `IVotes` token. |
| P1 | Zero-stake or bad-parameter deployment | `roundDuration = 0`, `vestingRounds = 0`, or a zero total stake can make core flows revert. | Deployment-time validation and operator runbooks. |
| P1 | Split funding trust mismatch | `processSplitWith` distinguishes terminal-style pull flows from controller-style pre-sent flows using caller authorization and allowance heuristics. | Restrict callers to verified terminals/controllers and test both paths. |

## 1. Trust Assumptions

- **JB directory.** `JB721Distributor` and `JBTokenDistributor` trust `DIRECTORY.isTerminalOf` and `DIRECTORY.controllerOf` to authenticate split-hook callers.
- **Stake source integrity.**
  - `JB721Distributor` trusts the 721 hook and its store for ownership, tier membership, burned counts, and `votingUnits`.
  - `JBTokenDistributor` trusts the target `IVotes` token's checkpointing (`getPastVotes`, `getPastTotalSupply`).
- **Deployment parameters.** The shared constructor does not validate `roundDuration` or `vestingRounds`. Deployers must choose sane non-zero values.

## 2. Economic Risks

- **Round snapshot timing has a zero-balance edge case.** `_takeSnapshotOf` treats `snapshot.balance != 0` as the "already snapshotted" sentinel. Once a round snapshots a non-zero tracked balance, later funding in the same round is excluded until a later round. But if the first snapshot for that `(hook, token, round)` sees `balance == 0`, later funding in the same round can still be picked up by a later `beginVesting` call because the stored zero-balance snapshot is indistinguishable from "no snapshot yet".
- **Unclaimed value stays in the pool.** `distributable = snapshot.balance - snapshot.vestingAmount`, so rewards not vested in the current round remain available for future rounds rather than being lost.
- **Partial-round claims are linear, not cliff-based.** `collectableFor` unlocks value proportionally as rounds elapse. Integrators should not assume "nothing until release round".
- **Forfeited 721 rewards are recycled, not burned.** `releaseForfeitedRewards` decrements `totalVestingAmountOf` but intentionally does not decrement `_balanceOf`, so burned-NFT rewards return to the hook's future distributable pool.
- **Undelegated `IVotes` supply can dilute participation.** `JBTokenDistributor` uses delegated voting power, not raw ERC-20 balances. Holders who never self-delegate may receive no stake weight while still contributing to total-supply expectations off-chain.

## 3. Access Control and Caller Risks

- **Vesting is permissionless.** Anyone can call `beginVesting`. This is intentional, but it means a third party can crystallize the current round's snapshot timing.
- **Claim authority differs by distributor.**
  - `JB721Distributor` only allows the current NFT owner to collect for a token ID.
  - `JBTokenDistributor` encodes the claimant address into `tokenId` and only that address can collect.
- **721 claim batches are brittle to invalid token IDs.** `JB721Distributor._canClaim` uses a direct `IERC721(hook).ownerOf(tokenId)` check without try-catch. Unlike `beginVesting`, which skips burned NFTs via `_tokenBurned`, a `collectFor` batch that includes a burned or never-minted token ID can revert before any claims in the batch are processed.
- **Forfeiture release is 721-only in practice.** `JBTokenDistributor._tokenBurned` always returns `false`, so `releaseForfeitedRewards` always reverts there.
- **Split-hook entry is tightly gated.** `processSplitWith` reverts unless the caller is the current project terminal or controller for `context.projectId`.

## 4. DoS and Liveness Risks

- **Zero stake reverts vesting.** `_vestTokenIds` uses `mulDiv(..., totalStakeAmount)`. If `_totalStake(...) == 0` and any token IDs are processed, `beginVesting` reverts.
- **Bad constructor parameters can brick the instance.**
  - `roundDuration = 0` breaks `currentRound()`.
  - `vestingRounds = 0` breaks the locked-share math in `collectableFor` and `_unlockTokenIds`.
- **721 total-stake enumeration is linear in tier count.** `JB721Distributor._totalStake` iterates all tier IDs up to `maxTierIdOf(hook)`. Large tier sets increase vesting gas.
- **Resolver or token callback failures can block payout collection.**
  - Native claims revert on failed ETH transfer.
  - ERC-20 claims inherit whatever revert behavior the reward token implements.

## 5. Integration Risks

- **Controller-vs-terminal split funding heuristic.** For ERC-20 splits, `processSplitWith` treats `allowance >= context.amount` as the terminal flow and otherwise assumes tokens were already sent by the controller. Integrators should preserve that calling convention.
- **Fee-on-transfer handling is asymmetric by design.** Terminal-style pull flows and direct `fund()` measure actual received balance deltas. Controller-style split flows trust `context.amount` because the tokens are presumed to have already been transferred.
- **721 stake weights depend on tier metadata, not token count alone.** A tier with higher `votingUnits` receives more rewards per NFT.
- **721 vesting and claiming treat burned tokens differently.** `beginVesting` skips burned NFTs to avoid overbooking new vesting, but `collectFor` still depends on `ownerOf(tokenId)` succeeding for authorization. Integrators should sanitize 721 claim batches off-chain instead of assuming the distributor will ignore invalid token IDs.
- **Checkpoint availability matters for `IVotes`.** If the target token lacks reliable historical checkpoints, `JBTokenDistributor` cannot allocate correctly.

## 6. Invariants to Verify

- For every `(hook, token)`, `totalVestingAmountOf <= _balanceOf`.
- Claim collections plus remaining vesting plus future distributable balance never exceed tracked funded balance for a `(hook, token)`.
- A `(hook, token, round)` snapshot is stable after the first non-zero-balance snapshot and reused for later vesting calls in the same round.
- `latestVestedIndexOf` only advances contiguously past fully exhausted vesting entries.
- In `JB721Distributor`, burned NFTs are excluded from total stake and can only have rewards recycled through `releaseForfeitedRewards`.
- In `JBTokenDistributor`, only the encoded address for a `tokenId` can collect that token's vested rewards.

## 7. Accepted Behaviors

### 7.1 Anyone can trigger a round snapshot

`beginVesting` is intentionally permissionless. This improves liveness, but it also means operators do not control the exact block at which a round snapshot is first taken, and zero-balance rounds are not fully crystallized until some later call snapshots a non-zero tracked balance.

### 7.2 Rewards can remain undistributed when stake is missing

If some potential participants have zero effective stake for a round, the corresponding reward value simply stays in the distributor's tracked balance for future rounds instead of being forcibly allocated.

### 7.3 721 and `IVotes` variants intentionally differ

The two distributors share the vesting engine but not the ownership model. `JB721Distributor` follows current NFT ownership, while `JBTokenDistributor` follows encoded claimant addresses and delegated checkpointed voting power.
