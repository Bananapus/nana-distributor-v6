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
- `JB721Distributor` distributes value to 721 holders using checkpointed voting power, ensuring only holders at the funded round's snapshot block are eligible

Both concrete distributors implement `IJBSplitHook`, which makes them usable directly from Juicebox payout splits.

Use this repo when the problem is "how do we distribute already-owned assets over time?" Do not use it when the problem is project accounting, treasury settlement, or terminal execution.

If the issue is "where did the project's value come from?" start in `nana-core-v6`, `nana-721-hook-v6`, or the upstream repo that minted or received the assets first.

## Key Contracts

| Contract | Role |
| --- | --- |
| `JBDistributor` | Shared round-based vesting, claiming, and accounting logic. |
| `JBTokenDistributor` | ERC-20 distributor keyed to `IVotes` checkpointed voting power. |
| `JB721Distributor` | NFT-aware distributor keyed to checkpointed voting power from the hook's `CHECKPOINTS()` module. Only NFTs held at the funded round's snapshot block are eligible. |

## Mental Model

1. a project funds the distributor, often through a payout split
2. accepted funding is assigned to the current reward round for the chosen token or 721 stake source
3. the distributor's immutable claim duration decides whether funded reward rounds expire
4. the encoded token staker or current NFT owner later claims completed past reward rounds into a fresh vesting entry
5. anyone can burn expired unclaimed reward rounds after their deadline
6. recipients collect their vested share as the configured vesting schedule unlocks
7. some unclaimable value can be reclaimed through explicit recovery paths, depending on the distributor type

This repo does not explain why an allocation exists. It only defines how funded inventory is handed out.

## Read These Files First

1. `src/interfaces/IJBDistributor.sol`
2. `src/JBDistributor.sol`
3. `src/JBTokenDistributor.sol`
4. `src/JB721Distributor.sol`

## Integration Traps

- distribution correctness depends on the distributor actually holding the assets it is expected to vest
- ERC-20 and ERC-721 distributions share historical reward-round accounting, but claim authority differs:
  token rewards are claimed by the encoded staker address, while 721 rewards are claimed by the current NFT owner
- `CLAIM_DURATION` is fixed at deployment; `0` means reward rounds do not expire, otherwise all funding paths use the
  same deadline measured from when the funded round first becomes claimable
- `burnExpiredRewards` is permissionless and only burns the unclaimed remainder; already-materialized vesting entries
  remain claimable on their normal vesting curve
- `releaseForfeitedRewards` matters for 721 distributions; token-vote distributions do not have the same burned-token path
- snapshot timing is part of the trusted surface
- this repo settles distributions, but it does not prove the upstream entitlement math was correct

## Where State Lives

- round and vesting state: `JBDistributor`
- historical reward-round inputs: `JBRewardRoundData`
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
forge build --deny notes
forge test --deny notes
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
- deployers that set a nonzero claim duration should choose a window long enough for expected claimants, because
  expired unclaimed rewards can be burned by anyone

## For AI Agents

- Treat this repo as distribution plumbing, not as the source of upstream entitlement math.
- Read both the ERC-20 and ERC-721 tests before claiming the flows are equivalent.
