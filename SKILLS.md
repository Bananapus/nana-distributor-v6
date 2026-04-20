# Juicebox Distributor

## Use This File For

- Use this file when the task involves round-based vesting, split-hook distribution, or snapshot-based payout allocation.
- Start here, then decide whether the issue is in shared vesting logic, `IVotes`-based stake measurement, or 721-based stake measurement.

## Read This Next

| If you need... | Open this next |
|---|---|
| Repo overview and architecture | [`README.md`](./README.md), [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Shared vesting engine | [`src/JBDistributor.sol`](./src/JBDistributor.sol), [`src/interfaces/IJBDistributor.sol`](./src/interfaces/IJBDistributor.sol) |
| Token distributor behavior | [`src/JBTokenDistributor.sol`](./src/JBTokenDistributor.sol) |
| 721 distributor behavior | [`src/JB721Distributor.sol`](./src/JB721Distributor.sol) |
| Types and structs | [`src/structs/`](./src/structs/) |
| Main tests | [`test/JBTokenDistributor.t.sol`](./test/JBTokenDistributor.t.sol), [`test/JB721Distributor.t.sol`](./test/JB721Distributor.t.sol), [`test/invariant/JB721DistributorInvariant.t.sol`](./test/invariant/JB721DistributorInvariant.t.sol) |

## Repo Map

| Area | Where to look |
|---|---|
| Main contracts | [`src/`](./src/) |
| Structs and interfaces | [`src/structs/`](./src/structs/), [`src/interfaces/`](./src/interfaces/) |
| Tests | [`test/`](./test/) |

## Purpose

Shared vesting and distribution engine for ERC-20 and 721-based payout flows.

## Working Rules

- Start in [`src/JBDistributor.sol`](./src/JBDistributor.sol) for shared round logic.
- Treat snapshot timing as part of correctness.
- `JBTokenDistributor` and `JB721Distributor` share a vesting engine but not the same ownership model.
- Verify the distributor actually holds the asset it is meant to vest before reasoning about payout correctness.
