# Juicebox Distributor

`@bananapus/distributor-v6` distributes ERC-20 balances or 721 token inventories to many recipients under round-based vesting rules. It is a payout utility package for Juicebox-adjacent flows, not a protocol accounting layer.

Architecture: [ARCHITECTURE.md](./ARCHITECTURE.md)  
User journeys: [USER_JOURNEYS.md](./USER_JOURNEYS.md)  
Skills: [SKILLS.md](./SKILLS.md)  
Risks: [RISKS.md](./RISKS.md)  
Administration: [ADMINISTRATION.md](./ADMINISTRATION.md)  
Audit instructions: [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md)

## Overview

This repo provides reusable distributors for teams that need deterministic post-funding or post-mint distribution.

The package separates distribution mechanics by asset type:

- `JBDistributor` coordinates shared round and vesting logic
- `JBTokenDistributor` distributes ERC-20 balances using `IVotes` checkpointed voting power
- `JB721Distributor` distributes value to 721 holders using tier voting units

Both concrete distributors implement `IJBSplitHook`, which makes them usable directly from Juicebox payout splits.

Use this repo when the problem is "how do we distribute already-owned assets over time?" Do not use it when the problem is project accounting, treasury settlement, or terminal execution.

If the issue is "where did the project's value come from?" start in `nana-core-v6`, `nana-721-hook-v6`, or the upstream repo that minted or received the assets first.

## Key Contracts

| Contract | Role |
| --- | --- |
| `JBDistributor` | Shared round-based vesting, claiming, and accounting logic. |
| `JBTokenDistributor` | ERC-20 distributor keyed to `IVotes` checkpointed voting power. |
| `JB721Distributor` | NFT-aware distributor keyed to tier voting units and holder state. |

## Mental Model

1. a project funds the distributor, often through a payout split
2. a vesting round begins and snapshots the eligible stake state
3. recipients collect their pro-rata share as that round vests
4. some unclaimable value can be reclaimed through explicit recovery paths, depending on the distributor type

This repo does not explain why an allocation exists. It only defines how funded inventory is handed out.

## Read These Files First

1. `src/interfaces/IJBDistributor.sol`
2. `src/JBDistributor.sol`
3. `src/JBTokenDistributor.sol`
4. `src/JB721Distributor.sol`

## Integration Traps

- distribution correctness depends on the distributor actually holding the assets it is expected to vest
- ERC-20 and ERC-721 distributions share a mental model, but their edge cases are different
- `releaseForfeitedRewards` matters for 721 distributions; token-vote distributions do not have the same burned-token path
- snapshot timing is part of the trusted surface
- this repo settles distributions, but it does not prove the upstream entitlement math was correct

## Where State Lives

- round and vesting state: `JBDistributor`
- token snapshot inputs: `JBTokenSnapshotData`
- vesting schedule state: `JBVestingData`
- asset-specific claim behavior: the concrete distributor

## High-Signal Tests

1. `test/JBTokenDistributor.t.sol`
2. `test/JB721Distributor.t.sol`
3. `test/invariant/JB721DistributorInvariant.t.sol`

## Install

```bash
npm install @bananapus/distributor-v6
```

## Development

```bash
npm install
forge build
forge test
```

Useful scripts:

- `npm run test:fork`
- `npm run deploy:mainnets`
- `npm run deploy:testnets`

## Repository Layout

```text
src/
  JBDistributor.sol
  JBTokenDistributor.sol
  JB721Distributor.sol
  interfaces/
  structs/
test/
  token, 721, and invariant coverage
script/
  Deploy.s.sol
```

## Risks And Notes

- distributors are only as trustworthy as the vesting parameters and funding they receive
- operational mistakes often come from funding the wrong asset or underfunding the distributor
- teams should review claim timing and snapshot assumptions with the same care they review the payout source

## For AI Agents

- Treat this repo as distribution plumbing, not as the source of upstream entitlement math.
- Read both the ERC-20 and ERC-721 tests before claiming the flows are equivalent.
