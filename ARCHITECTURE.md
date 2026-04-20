# Architecture

## Purpose

`nana-distributor-v6` distributes ERC-20 or native-token rewards to token holders over time. It supports two staking models: Juicebox 721 holders through `JB721Distributor` and delegated-vote holders of an `IVotes` token through `JBTokenDistributor`.

## System Overview

`JBDistributor` is the abstract vesting and snapshot engine. Concrete distributors decide who can claim, how stake weight is measured, and how total stake is computed for each round. Both concrete contracts also implement `IJBSplitHook`, so Juicebox projects can route payout splits directly into the distributor that serves their staker base.

## Core Invariants

- Rewards are distributed round by round from snapshots taken at round boundaries.
- Vesting schedules are linear across `vestingRounds`.
- Claim rights must be tied to the actual current owner or encoded claimant model of the staking asset.
- Snapshot stake totals and per-token stake lookups must use the same round boundary.
- Beginning vesting snapshots the current round's total stake once; later ownership changes affect who can claim, not the historical round allocation itself.
- Burned 721 positions can forfeit unvested rewards; non-delegated `IVotes` supply remains unclaimable and stays in the pool for future rounds.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBDistributor` | Funding, round math, vesting state, and generic claim logic | Abstract base |
| `JB721Distributor` | Reward distribution to 721 holders by tier voting units | Split hook + staking adapter |
| `JBTokenDistributor` | Reward distribution to `IVotes` holders by checkpointed delegated voting power | Split hook + staking adapter |
| `JBTokenSnapshotData`, `JBVestingData` | Snapshot and vesting structs | Shared accounting data |

## Trust Boundaries

- Juicebox terminals and controllers are trusted only as authorized sources for split-hook funding calls.
- `JB721Distributor` trusts `nana-721-hook-v6` tier and burn semantics to measure stake.
- `JBTokenDistributor` trusts `IVotes.getPastVotes(...)` and `getPastTotalSupply(...)` checkpoint data.
- Treasury accounting for the source project stays in `nana-core-v6`; this repo only accounts for reward custody and vesting once funds arrive.

## Critical Flows

### Fund

```text
funder or split hook
  -> sends ERC-20 or native funds for a specific staking hook
  -> distributor credits the actual received amount
  -> balance becomes available for future round vesting
```

### Begin Vesting

```text
authorized caller
  -> selects a hook and reward token
  -> distributor snapshots total stake for the current round
  -> reward amount is assigned into round-based vesting entries
```

### Claim Or Collect

```text
claimant
  -> distributor checks ownership or encoded claimant rights
  -> computes vested or collectable share across vesting entries
  -> transfers claimable funds and updates claimed-share state
```

## Accounting Model

- Rounds are block-based from `startingBlock` and `roundDuration`.
- `MAX_SHARE` is `100_000` and is used for vesting-share accounting.
- `JBDistributor` stores reward balances per `hook` and `token`, round snapshots, and per-tokenId vesting entries.
- The repo uses actual received balance deltas for ERC-20 funding paths to tolerate fee-on-transfer ingress.

## Security Model

- Snapshot consistency is the main correctness requirement; stake totals and individual stake lookups must refer to the same round boundary.
- `JB721Distributor` has a gas-sensitive total-stake loop over tiers.
- Authorization on `processSplitWith(...)` must remain limited to a terminal or controller recognized by `JBDirectory`.
- Claim semantics differ by staking model: 721 burns can make rewards permanently unclaimable, while `IVotes` delegation state determines whether supply participates at all.
- Burn handling differs by distributor type and is part of the economic model.

## Safe Change Guide

- Review `JBDistributor` first before changing either concrete distributor.
- If round timing changes, re-check snapshot block selection and claim math together.
- If 721 stake semantics change, inspect `tierOfTokenId(...)`, total-stake iteration, and burn handling in one review.
- If claimant rules change, re-check how historical vesting entries interact with current ownership or delegation at claim time.
- If `IVotes` stake semantics change, keep `getPastVotes(...)` and `getPastTotalSupply(...)` aligned.

## Canonical Checks

- 721 round funding, vesting, and claim paths:
  `test/JB721Distributor.t.sol`
- delegated-votes snapshot and claim semantics:
  `test/JBTokenDistributor.t.sol`
- 721 distributor state-machine invariants:
  `test/invariant/JB721DistributorInvariant.t.sol`

## Source Map

- `src/JBDistributor.sol`
- `src/JB721Distributor.sol`
- `src/JBTokenDistributor.sol`
- `test/JB721Distributor.t.sol`
- `test/JBTokenDistributor.t.sol`
- `test/invariant/JB721DistributorInvariant.t.sol`
