# Juicebox Distributor

`@bananapus/distributor-v6` distributes ERC-20 balances or 721 token inventories to many recipients under round-based vesting rules. It is a payout utility package for Juicebox-adjacent flows, not a protocol accounting layer.

## Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md) — system overview, modules, trust boundaries, and core invariants.
- [USER_JOURNEYS.md](./USER_JOURNEYS.md) — end-to-end flows for funders and claimants across token and 721 variants.
- [INVARIANTS.md](./INVARIANTS.md) — per-section invariants for snapshot fairness, vesting math, beneficiary routing, loans, and recycling.
- [RISKS.md](./RISKS.md) — risk register with priority risks and the minimum invariants to verify.
- [ADMINISTRATION.md](./ADMINISTRATION.md) — deployment parameters, control posture, and recovery guidance.
- [SKILLS.md](./SKILLS.md) — quick index for routing tasks into the right sub-document.
- [STYLE_GUIDE.md](./STYLE_GUIDE.md) — Solidity and repo conventions used across the Juicebox V6 ecosystem.
- [AUDIT_INSTRUCTIONS.md](./AUDIT_INSTRUCTIONS.md) — audit framing, targets, and suggested hunting grounds.
- [CHANGELOG.md](./CHANGELOG.md) - V5 to V6 migration changelog.

## Overview

This repo provides reusable distributors for teams that need deterministic post-funding or post-mint distribution.

The package separates distribution mechanics by asset type:

- `JBDistributor` coordinates shared round and vesting logic
- `JBTokenDistributor` distributes ERC-20 balances using `IVotes` checkpointed voting power
- `JB721Distributor` distributes value to active 721 holders using the hook's checkpointed owner and active-vote data, ensuring only holders at the funded round's snapshot block are eligible

Both concrete distributors implement `IJBSplitHook`, which makes them usable directly from Juicebox payout splits.

Use this repo when the problem is "how do we distribute already-owned assets over time?" Do not use it when the problem is project accounting, treasury settlement, or terminal execution.

If the issue is "where did the project's value come from?" start in `nana-core-v6`, `nana-721-hook-v6`, or the upstream repo that minted or received the assets first.

## Key contracts

| Contract | Role |
| --- | --- |
| `JBDistributor` | Shared round-based vesting, claiming, and accounting logic. |
| `JBTokenDistributor` | ERC-20 distributor keyed to `IVotes` checkpointed voting power. |
| `JB721Distributor` | NFT-aware distributor keyed to checkpointed voting power from the hook's checkpoint module. Only NFTs held at the funded round's snapshot block are eligible. |

## Mental model

1. a project funds the distributor, often through a payout split
2. accepted funding is assigned to the current reward round for the chosen token or 721 stake source
3. each funded reward round records an active-vote snapshot denominator for its token, collection, or tier group
4. anyone can start vesting completed past reward rounds for an encoded token staker or current NFT owner
5. anyone can recycle expired reward-round inventory that has not started vesting after the claim deadline
6. recipients collect their vested share as the configured vesting schedule unlocks; helpers can collect only to the
   canonical holder
7. eligible claimants can borrow against vesting revnet rewards without bypassing the vesting schedule
8. some unclaimable value can be recycled through explicit cleanup paths, depending on the distributor type

This repo does not explain why an allocation exists. It only defines how funded inventory is handed out.

## Read these files first

1. `src/interfaces/IJBDistributor.sol`
2. `src/JBDistributor.sol`
3. `src/JBTokenDistributor.sol`
4. `src/JB721Distributor.sol`

## Integration traps

- distribution correctness depends on the distributor actually holding the assets it is expected to vest
- ERC-20 and ERC-721 distributions share historical reward-round accounting, but their canonical beneficiaries differ:
  token rewards belong to the encoded staker address, while 721 rewards belong to the current NFT owner
- `beginVesting` is permissionless because no value leaves the distributor; `collectVestedRewards` is permissionless
  only when paid to the canonical beneficiary, while an authorized holder can still choose any beneficiary
- `CLAIM_DURATION` is fixed at deployment; `0` means reward rounds do not expire, while nonzero values set the window
  after which unmaterialized reward inventory can be recycled
- token distributors record `IJBActiveVotes.getPastTotalActiveVotes` at the funded round's snapshot block; only
  addresses with `getPastVotes` at that block share the pot
- 721 distributors record the hook checkpoint module's active total for all-tiers rewards, or the summed active totals
  for a tier-scoped reward group; both modes cap each NFT claim by the snapshot owner's remaining active units for that
  NFT's tier
- `recycleExpiredRewards` is permissionless; it recycles the expired round's unmaterialized remainder while preserving
  amounts that already started vesting
- eligible expired and forfeited rewards stay in distributor inventory and are recycled into the current reward round
- revnet loan-backed vesting is opt-in at deployment; the reward token must be a REVOwner-owned revnet token, the
  distributor keeps the loan NFT, and repayment restores the original vesting schedule instead of releasing all
  collateral immediately
- if Revnet liquidates a distributor-held vesting loan, anyone can call `writeOffLiquidatedVestingLoan` to clear the
  stale collection lock and forfeit only the vesting rewards that were collateralized by that loan
- distributors deployed with `VESTING_ROUNDS == 0` disable revnet vesting loans because rewards are immediately
  collectible instead of locked in a vesting position
- `releaseForfeitedRewards` matters for 721 distributions; token-vote distributions do not have the same burned-token
  forfeiture path
- reward, vesting, and loan accounting carries a `groupId`: `0` is the all-tiers group (the default pool), a non-zero
  group is `keccak256(abi.encode(tierIds))`. The tier overloads live on `JB721Distributor`; the base is tier-agnostic.
  Split funding via `processSplitWith` always lands in group 0 — a split cannot carry a tier set; tier-scoped pots
  require the explicit `fund(hook, tierIds, token, amount)` overload, and claims/collections must pass the same
  `tierIds` to hit that group
- tier-scoped 721 pots weigh each eligible NFT by its tier's `votingUnits` against a summed
  `getPastTotalTierActiveVotes` denominator, then cap each numerator with `getPastAccountTierActiveVotes`; this
  requires `@bananapus/721-hook-v6 >= 0.0.73` for the active-vote checkpoints API
- snapshot timing is part of the trusted surface
- this repo settles distributions, but it does not prove the upstream entitlement math was correct

## Where state lives

- round and vesting state: `JBDistributor`
- historical reward-round inputs: `JBRewardRoundData`
- vesting schedule state: `JBVestingData`
- asset-specific claim behavior: the concrete distributor

## High-signal tests

1. `test/JBTokenDistributor.t.sol`
2. `test/JB721Distributor.t.sol`
3. `test/invariant/JB721DistributorInvariant.t.sol`
4. `test/regression/VestingLoanRegression.t.sol`

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

## Repository layout

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

## Risks and notes

- distributors are only as trustworthy as the vesting parameters and funding they receive
- operational mistakes often come from funding the wrong asset or underfunding the distributor
- teams should review claim timing and snapshot assumptions with the same care they review the payout source
- token distributors require hooks that expose `IJBActiveVotes`; expiring token rounds recycle any unmaterialized
  remainder after the deadline

## For AI agents

- Treat this repo as distribution plumbing, not as the source of upstream entitlement math.
- Read both the ERC-20 and ERC-721 tests before claiming the flows are equivalent.
