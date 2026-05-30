# Architecture

## Purpose

`nana-distributor-v6` provides round-based vesting and claiming for already-owned assets. It supports both `IVotes`-based ERC-20 distributions and 721-based distributions without becoming a treasury or accounting layer.

## System Overview

`JBDistributor` is the shared vesting engine. `JBTokenDistributor` assigns accepted funding to historical reward rounds keyed by checkpointed `IVotes` power, then lets each encoded staker lazily claim past rounds into a fresh vesting entry. `JB721Distributor` follows the same historical-round pattern for NFT owners, using the 721 hook's `CHECKPOINTS()` module and tier voting units to decide each funded round's eligible NFT stake.

Both variants can be used as `IJBSplitHook` receivers. Each deployment has one immutable claim duration: `0` keeps reward rounds non-expiring, while a nonzero duration lets unclaimed remainders be recycled permissionlessly after the configured claim window.

## Core Invariants

- snapshot timing must stay coherent
- tracked funded balance must cover current vesting obligations
- claim authority must match the distributor type
- expired recycling must only move unclaimed reward-round inventory
- 721 forfeiture handling must not over-allocate or recycle value accidentally
- token and 721 variants must preserve the same core vesting math

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `JBDistributor` | Shared rounds, vesting, snapshots, and claims | Economic core |
| `JBTokenDistributor` | ERC-20 distribution using `IVotes` checkpoints | Token stake source |
| `JB721Distributor` | NFT distribution using checkpointed voting power | 721 stake source |

## Trust Boundaries

- split-hook caller authentication depends on `JBDirectory`
- `JBTokenDistributor` trusts `IVotes` checkpoint history
- `JB721Distributor` trusts the 721 hook's `CHECKPOINTS()` module for historical voting power and the store for tier metadata
- upstream entitlement logic still lives outside this repo

## Critical Flows

### Token Funding And Claim

```text
fund token distributor
  -> assign accepted amount to current reward round
  -> record snapshot block and total IVotes supply for that round
  -> record the deployment's fixed claim deadline when the duration is nonzero
  -> staker later claims rounds <= currentRound - 1
  -> one fresh vesting entry starts at claim time
```

### 721 Funding And Claim

```text
fund 721 distributor
  -> assign accepted amount to current reward round
  -> record snapshot block and total 721 checkpointed stake for that round
  -> record the deployment's fixed claim deadline when the duration is nonzero
  -> current NFT owner later claims rounds <= currentRound - 1
  -> one fresh vesting entry starts at claim time
```

### Expired Reward Recycle

```text
any caller
  -> provide hook, reward token, and expired reward rounds
  -> distributor skips non-expired or already-settled rounds
  -> unclaimed remainder is funded amount minus amount already materialized into vesting
  -> unclaimed remainder stays in tracked inventory and is recorded into the current reward round
```

### Revnet Vesting Loan Write-Off

```text
any caller
  -> liquidate an expired distributor-held loan through Revnet loans
  -> call writeOffLiquidatedVestingLoan with the liquidated loan ID
  -> distributor confirms Revnet deleted the loan data
  -> collateralized vesting entries are marked forfeited
  -> the stale collection lock is cleared while newer vesting entries remain collectable
```

### Collect

```text
claimant
  -> prove authority for the token ID or encoded claimant slot
  -> compute unlocked share
  -> transfer the vested amount
```

### Tier-Scoped Rewards

Every reward, vesting, and loan record carries a `groupId` dimension. `groupId == 0` is the legacy all-tiers group and behaves exactly as before — all the existing signatures are unchanged and fully backward compatible. A non-zero group is `keccak256(abi.encode(tierIds))` for a strictly-increasing tier set, recorded on the group's first funding and queryable via `tierIdsOf(hook, groupId)`.

```text
fund a tier-scoped pot
  -> fund(hook, tierIds, token, amount)
  -> tier set recorded on first funding, group ID derived from the tier set
  -> only holders of NFTs in those tiers can claim that pot
  -> tier-scoped overloads of beginVesting / collectVestedRewards / borrowAgainstVesting /
     burnExpiredRewards / releaseForfeitedRewards thread the same groupId
```

- **Denominator.** For a tier-scoped pot, `JB721Distributor` computes the round's total stake as the summed `getPastTierVotingUnits(tierId, snapshotBlock)` over the funded tier set (from the 721 hook's checkpoints module). Each eligible NFT — its tier is in the set and it existed at the round snapshot — contributes its tier's `votingUnits`. There is **no per-owner vote cap** on the tier path; eligibility plus tier membership matches exactly the set the denominator counts, so numerator and denominator reconcile. The legacy group-0 path keeps its existing owner-cap logic.
- **Token distributors are group-agnostic.** `JBTokenDistributor` threads `groupId` only for storage isolation; its stake weight stays global `getPastTotalSupply` because token distributors have no tier concept.
- **Split funding is group-0 only.** `processSplitWith` always records funding under group 0 — a split cannot carry a tier set. Tier-scoped pots require the explicit `fund(hook, tierIds, token, amount)`.

## Accounting Model

This repo owns vesting-round accounting. It does not own upstream treasury accounting or entitlement creation.

The main variables are snapshot balance, total vesting amount, reward-round claimed amount, optional claim deadline, and the stake source used to split each round.

## Security Model

- wrong snapshots can misallocate a whole round
- bad constructor parameters can brick a distributor instance
- split-funding caller assumptions matter because `processSplitWith` expects an ERC-20 allowance and pulls tokens via `transferFrom`
- claim-duration assumptions matter because expired unclaimed rewards are recyclable by anyone
- 721 and token variants intentionally differ in ownership model and forfeiture behavior

## Safe Change Guide

- review snapshot timing and vesting math together
- if claim authority changes, re-check both distributor variants separately
- if funding semantics change, test the allowance-based `transferFrom` flow explicitly

## Canonical Checks

- token distribution behavior:
  `test/JBTokenDistributor.t.sol`
- 721 distribution behavior:
  `test/JB721Distributor.t.sol`
- 721 invariants:
  `test/invariant/JB721DistributorInvariant.t.sol`

## Source Map

- `src/JBDistributor.sol`
- `src/JBTokenDistributor.sol`
- `src/JB721Distributor.sol`
- `src/interfaces/IJBDistributor.sol`
