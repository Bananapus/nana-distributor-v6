# Architecture

## Purpose

`nana-distributor-v6` provides round-based vesting and claiming for already-owned assets. It supports both `IVotes`-based ERC-20 distributions and 721-based distributions without becoming a treasury or accounting layer.

## System Overview

`JBDistributor` is the shared vesting engine. `JBTokenDistributor` changes stake measurement to checkpointed voting power. `JB721Distributor` changes stake measurement to checkpointed voting power from the hook's `CHECKPOINTS()` module, ensuring only NFTs held at round start are eligible.

Both variants can be used as `IJBSplitHook` receivers.

## Core Invariants

- snapshot timing must stay coherent
- tracked funded balance must cover current vesting obligations
- claim authority must match the distributor type
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

### Begin Vesting

```text
funded distributor
  -> begin a round
  -> snapshot stake and tracked balance for that round
  -> record vesting entries for the requested token IDs
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

The main variables are snapshot balance, total vesting amount, and the stake source used to split each round.

## Security Model

- wrong snapshots can misallocate a whole round
- bad constructor parameters can brick a distributor instance
- split-funding caller assumptions matter because `processSplitWith` distinguishes pull and pre-sent flows
- 721 and token variants intentionally differ in authority and forfeiture behavior

## Safe Change Guide

- review snapshot timing and vesting math together
- if claim authority changes, re-check both distributor variants separately
- if funding semantics change, test terminal-style and controller-style flows explicitly

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
