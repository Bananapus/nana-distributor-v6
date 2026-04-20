# User Journeys

## Repo Purpose

This repo provides split-hook distributors that vest rewards to project stakeholders over time.
It does not decide treasury policy on its own. A project chooses to route payout value into these distributors through
split configuration in [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md).

## Primary Actors

- project operators who want payouts to vest to stakers instead of transferring immediately
- NFT holders claiming rewards based on 721 tier voting units
- token holders claiming rewards based on `IVotes` delegated voting power
- auditors reviewing vesting, snapshot, and forfeiture semantics

## Key Surfaces

- `JBDistributor`: shared funding, round math, vesting, forfeiture release, and claim accounting
- `JB721Distributor`: split hook that vests rewards to holders of a `JB721TiersHook`
- `JBTokenDistributor`: split hook that vests rewards to holders of an `IVotes` token
- `processSplitWith(...)`, `fund(...)`, `beginVesting(...)`, `collectVestedRewards(...)`, `releaseForfeitedRewards(...)`: main external lifecycle

## Journey 1: Fund A Distributor Through A Project Payout Split

**Actor:** project operator configuring payout policy.

**Intent:** send payout value into a vesting distributor instead of directly to recipients.

**Preconditions**
- the project has a payout split that points at `JB721Distributor` or `JBTokenDistributor`
- the split beneficiary is the hook or token whose holders should earn rewards
- the caller is a terminal or controller path the distributor recognizes

**Main Flow**
1. Configure the project payout split so the distributor is the split hook.
2. During payout execution, `processSplitWith(...)` is called on the distributor.
3. The distributor distinguishes terminal-style pull flows from controller-style pre-sent flows.
4. The hook-specific distributor balance is credited for future vesting rounds.

**Failure Modes**
- the split beneficiary is not the intended 721 hook or `IVotes` token
- an unauthorized caller tries to invoke `processSplitWith(...)`
- the funding path is misclassified between allowance-pull and pre-funded controller flow
- teams expect this repo to create the payout split automatically

**Postconditions**
- the relevant distributor balance is funded and available for a later vesting round

## Journey 2: Begin A New Vesting Round

**Actor:** operator or automation that starts reward distribution for the current round.

**Intent:** convert accumulated distributor balance into a snapshot-backed vesting schedule.

**Preconditions**
- the distributor has a positive balance for the target hook and token
- a vesting process for that round has not already started
- the project understands whether stake is measured by 721 voting units or `IVotes` checkpoints

**Main Flow**
1. Call the vesting entrypoint for the relevant distributor and hook.
2. `beginVesting(...)` snapshots stake at the current round boundary and fixes the round's distributable balance.
3. Reward amounts become claimable over `vestingRounds` rather than immediately.

**Failure Modes**
- vesting was already started for that round
- the chosen staking surface has zero usable stake
- another caller triggers the snapshot earlier in the round than operators expected
- integrators ignore that `JBTokenDistributor` depends on delegated voting power, not raw balances

**Postconditions**
- the round has a fixed distributable balance and snapshot-backed vesting schedule

## Journey 3: Claim And Collect Vested Rewards

**Actor:** eligible NFT holder or token holder.

**Intent:** collect the portion of rewards that has vested for their token or delegated stake.

**Preconditions**
- a vesting round has already been started
- the caller owns the 721 token or is the encoded token-holder address for the `IVotes` path
- some rewards are already collectable for the current round

**Main Flow**
1. Query `collectableFor(...)` or `claimedFor(...)` to inspect position state.
2. Call `collectVestedRewards(...)` for the token IDs, reward token, and beneficiary.
3. The distributor releases the vested amount and updates claim accounting.

**Failure Modes**
- the caller is not the token owner or encoded staker
- the rewards are still locked by the vesting schedule
- the beneficiary expects cliff-style unlocks instead of linear vesting
- teams misread `claimedFor(...)` as "available now" instead of "total amount represented by vesting entries"

**Postconditions**
- vested rewards are transferred and claim accounting advances for the holder's position

## Journey 4: Release Forfeited Rewards From Burned 721 Positions

**Actor:** operator or maintenance flow on the 721 distributor path.

**Intent:** recover unvested rewards that belong to 721 NFTs which were burned before claiming.

**Preconditions**
- the project uses `JB721Distributor`
- the target NFT was burned
- some vesting amount remains unclaimed for that token

**Main Flow**
1. Detect that a 721 position used for staking has been burned.
2. Call `releaseForfeitedRewards(...)` so unvested rewards are no longer stranded against a dead token.
3. Let the reclaimed amount return to the distributor pool for future rounds or accounting.

**Failure Modes**
- the token was not actually burned
- reviewers assume the same forfeiture path exists for `IVotes` staking, which it does not

**Postconditions**
- unvested rewards are no longer stranded against a burned 721 position

## Trust Boundaries

- `JB721Distributor` trusts the underlying 721 hook store for tier and voting-unit state
- `JBTokenDistributor` trusts `IVotes` checkpoint history and delegated voting power
- both distributors trust core payout execution to call `processSplitWith(...)` from valid controller or terminal paths

## Hand-Offs

- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) when the question is about payout split configuration or terminal accounting.
- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md) when the staking surface is a tiered NFT collection.
