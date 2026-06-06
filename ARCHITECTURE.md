# Architecture

## Purpose

`nana-distributor-v6` provides round-based vesting and claiming for already-owned assets. It supports both `IVotes`-based ERC-20 distributions and 721-based distributions without becoming a treasury or accounting layer.

## System overview

`JBDistributor` is the shared vesting engine. `JBTokenDistributor` assigns accepted funding to historical reward rounds keyed by checkpointed `IVotes` power, then lets each encoded staker lazily claim past rounds into a fresh vesting entry. `JB721Distributor` follows the same historical-round pattern for NFT owners, using the 721 hook's `CHECKPOINTS()` module and tier voting units to decide each funded round's eligible NFT stake.

Both variants can be used as `IJBSplitHook` receivers. Each deployment has one immutable claim duration: `0` keeps token reward rounds on the non-expiring total-supply path, while a nonzero duration makes token rounds active-voter rounds. Active-voter rounds record `IJBActiveVotes.getPastTotalActiveVotes` at funding and split rewards only among addresses with snapshot `getPastVotes`; rounds with no active votes can be recycled permissionlessly after the deadline.

## Core invariants

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

## Trust boundaries

- split-hook caller authentication depends on `JBDirectory`
- `JBTokenDistributor` trusts `IVotes` checkpoint history
- `JB721Distributor` trusts the 721 hook's `CHECKPOINTS()` module for historical voting power and the store for tier metadata
- upstream entitlement logic still lives outside this repo

## Critical flows

### Token funding and claim

```text
fund token distributor
  -> assign accepted amount to current reward round
  -> record snapshot block
  -> if claim duration is 0, record total IVotes supply for that round
  -> if claim duration is nonzero, record total active votes for that round
  -> staker later claims rounds <= currentRound - 1
  -> one fresh vesting entry starts at claim time
```

### 721 funding and claim

```text
fund 721 distributor
  -> assign accepted amount to current reward round
  -> record snapshot block and total 721 checkpointed stake for that round
  -> record the deployment's fixed claim deadline when the duration is nonzero
  -> current NFT owner later claims rounds <= currentRound - 1
  -> one fresh vesting entry starts at claim time
```

### Expired reward recycle

```text
any caller
  -> provide hook, reward token, and expired reward rounds
  -> distributor skips non-expired or already-settled rounds
  -> active-voter token rounds with nonzero active votes are left for snapshot voters to claim
  -> otherwise recyclable amount is funded amount minus amount already materialized into vesting
  -> recyclable amount stays in tracked inventory and is recorded into the current reward round
```

### Revnet vesting loan write-off

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

### Tier-scoped rewards

Every reward, vesting, and loan record carries a `groupId` dimension. `groupId == 0` is the all-tiers group — the default pool, acted on by the plain `fund`/`beginVesting`/`collectVestedRewards`/… signatures that take no `tierIds`. A non-zero group is `keccak256(abi.encode(tierIds))` for a strictly-increasing tier set, recorded on the group's first funding and queryable via `tierIdsOf(hook, groupId)`. The base `JBDistributor` is tier-agnostic — it only knows generic groups; the tier→`groupId` mapping lives entirely in `JB721Distributor`.

```text
fund a tier-scoped pot
  -> fund(hook, tierIds, token, amount)
  -> tier set recorded on first funding, group ID derived from the tier set
  -> only holders of NFTs in those tiers can claim that pot
  -> tier-scoped overloads of beginVesting / collectVestedRewards / borrowAgainstVesting /
     recycleExpiredRewards / releaseForfeitedRewards thread the same groupId
```

- **Denominator and numerator.** For the all-tiers group, `JB721Distributor` records `getPastTotalActiveVotes(snapshotBlock)` from the 721 hook's checkpoints module. For a tier-scoped pot, it records the summed `getPastTotalTierActiveVotes(tierId, snapshotBlock)` over the funded tier set. Both modes claim with the same numerator rule: each eligible NFT contributes up to its tier's `votingUnits`, capped by the snapshot owner's remaining `getPastAccountTierActiveVotes(owner, tierId, snapshotBlock)` for that reward group.
- **Token distributors are group-agnostic.** `JBTokenDistributor` threads `groupId` only for storage isolation; token weight never has a tier dimension. Non-expiring token rounds use global `getPastTotalSupply`, while active-voter token rounds use `getPastTotalActiveVotes`.
- **Split funding is group-0 only.** `processSplitWith` always records funding under group 0 — a split cannot carry a tier set. Tier-scoped pots require the explicit `fund(hook, tierIds, token, amount)`.

## Accounting model

This repo owns vesting-round accounting. It does not own upstream treasury accounting or entitlement creation.

The main variables are snapshot balance, total vesting amount, reward-round claimed amount, optional claim deadline, and the stake source used to split each round.

## Security model

- wrong snapshots can misallocate a whole round
- bad constructor parameters can brick a distributor instance
- split-funding caller assumptions matter because `processSplitWith` expects an ERC-20 allowance and pulls tokens via `transferFrom`
- claim-duration assumptions matter because token active-voter rounds require hooks with an active-vote total, and
  rounds with no active votes are recyclable by anyone
- 721 and token variants intentionally differ in ownership model and forfeiture behavior

## Safe change guide

- review snapshot timing and vesting math together
- if claim authority changes, re-check both distributor variants separately
- if funding semantics change, test the allowance-based `transferFrom` flow explicitly

## Canonical checks

- token distribution behavior:
  `test/JBTokenDistributor.t.sol`
- 721 distribution behavior:
  `test/JB721Distributor.t.sol`
- 721 invariants:
  `test/invariant/JB721DistributorInvariant.t.sol`

## Source map

- `src/JBDistributor.sol`
- `src/JBTokenDistributor.sol`
- `src/JB721Distributor.sol`
- `src/interfaces/IJBDistributor.sol`
