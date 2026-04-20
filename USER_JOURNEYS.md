# User Journeys

## Repo Purpose

This repo distributes already-owned assets over time. It snapshots stake, starts vesting rounds, and lets eligible recipients collect what has unlocked.

## Primary Actors

- teams funding a distributor from a split or post-mint allocation
- token holders or NFT holders collecting vested rewards
- operators configuring round timing and deployment shape
- auditors reviewing snapshot timing and stake-accounting correctness

## Key Surfaces

- `JBDistributor`: shared round and vesting engine
- `JBTokenDistributor`: ERC-20 distributor using `IVotes`
- `JB721Distributor`: NFT distributor using tier voting units

## Journey 1: Fund A Distributor

**Actor:** project or payout flow.

**Intent:** move owned assets into a distributor that will vest them over time.

**Preconditions**
- the correct asset and distributor type are chosen
- the distributor actually receives the inventory it is expected to vest

**Main Flow**
1. Fund the distributor directly or through a payout split.
2. Confirm the tracked balance matches what the distributor received.
3. Use the distributor as the vesting surface, not as the source of entitlement logic.

**Failure Modes**
- wrong asset funded
- underfunded distributor
- caller assumes funding alone starts vesting

**Postconditions**
- the distributor holds the asset inventory for future rounds

## Journey 2: Start A Vesting Round

**Actor:** any caller.

**Intent:** snapshot the current round and begin vesting.

**Preconditions**
- the round timing and parameters are valid
- the stake source is usable and non-zero

**Main Flow**
1. Call `beginVesting`.
2. The distributor snapshots the relevant balance and stake source.
3. Vesting entries become claimable over the configured schedule.

**Failure Modes**
- zero total stake
- bad deployment parameters such as zero round duration or zero vesting rounds
- stake snapshot is stale or surprising to operators

**Postconditions**
- a new vesting round exists with fixed snapshot assumptions

## Journey 3: Collect Vested Rewards

**Actor:** eligible recipient.

**Intent:** collect the share that has unlocked for a round.

**Preconditions**
- the recipient is authorized under the distributor type
- some share has already vested

**Main Flow**
1. Call the relevant claim function.
2. The distributor checks authority and unlocked amount.
3. The vested share transfers to the claimant.

**Failure Modes**
- invalid claimant
- claim batch includes invalid 721 token IDs
- reward token transfer fails

**Postconditions**
- vested rewards move to the claimant

## Journey 4: Recycle Forfeited 721 Rewards

**Actor:** caller using the 721 distributor path.

**Intent:** release rewards tied to burned NFTs back into the future distribution pool.

**Preconditions**
- the distributor type is 721-based
- the relevant NFTs are burned or otherwise forfeited under the configured rules

**Main Flow**
1. Call the forfeiture-release path.
2. The distributor reduces current vesting obligations for those forfeited claims.
3. The value remains in the distributor for future rounds instead of being destroyed.

**Failure Modes**
- caller expects the same behavior from the token distributor
- off-chain systems treat forfeited value as burned instead of recycled

**Postconditions**
- forfeited 721 rewards return to the future distributable pool

## Trust Boundaries

- this repo trusts `JBDirectory` for authenticated split-hook caller checks
- `JBTokenDistributor` trusts `IVotes` checkpoints
- `JB721Distributor` trusts the 721 hook's `CHECKPOINTS()` module for historical voting power and the store for tier metadata

## Hand-Offs

- Use the upstream repo that funded the distributor when the question is about why an allocation exists.
- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md) when the stake source is a tiered 721 hook.
