# Architecture

## Purpose

`nana-distributor-v6` provides round-based vesting and claiming for already-owned assets. It supports both `IVotes`-based ERC-20 distributions and 721-based distributions without becoming a treasury or accounting layer.

## System Overview

`JBDistributor` is the shared vesting engine. `JBTokenDistributor` assigns accepted funding to historical reward rounds keyed by checkpointed `IVotes` power, then lets each encoded staker lazily claim past rounds into a fresh vesting entry. `JB721Distributor` now follows the same historical-round pattern for NFT owners, using the 721 hook's `CHECKPOINTS()` module and tier voting units to decide each funded round's eligible NFT stake.

Both variants can be used as `IJBSplitHook` receivers. Each deployment has one immutable claim duration: `0` keeps reward rounds non-expiring, while a nonzero duration lets unclaimed remainders be burned permissionlessly after the configured claim window.

## Core Invariants

- snapshot timing must stay coherent
- tracked funded balance must cover current vesting obligations
- claim authority must match the distributor type
- expired burns must only remove unclaimed reward-round inventory
- 721 forfeiture handling must not over-allocate or burn value accidentally
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

### Expired Reward Burn

```text
any caller
  -> provide hook, reward token, and expired reward rounds
  -> distributor skips non-expired or already-settled rounds
  -> unclaimed remainder is funded amount minus amount already materialized into vesting
  -> unclaimed remainder leaves tracked inventory and is sent to the burn sink
```

### Collect

```text
claimant
  -> prove authority for the token ID or encoded claimant slot
  -> compute unlocked share
  -> transfer the vested amount
```

## Accounting Model

This repo owns vesting-round accounting. It does not own upstream treasury accounting or entitlement creation.

The main variables are snapshot balance, total vesting amount, reward-round claimed amount, optional claim deadline, and the stake source used to split each round.

## Security Model

- wrong snapshots can misallocate a whole round
- bad constructor parameters can brick a distributor instance
- split-funding caller assumptions matter because `processSplitWith` expects an ERC-20 allowance and pulls tokens via `transferFrom`
- claim-duration assumptions matter because expired unclaimed rewards are burnable by anyone
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
