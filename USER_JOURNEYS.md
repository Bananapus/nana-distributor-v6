# User Journeys

## Repo Purpose

This repo distributes already-owned assets over time. Token rewards are assigned to historical funding rounds and start vesting when the staker claims; 721 rewards use the shared round snapshot and vesting flow.

## Primary Actors

- teams funding a distributor from a split or post-mint allocation
- token holders or NFT holders collecting vested rewards
- operators configuring round timing and deployment shape
- auditors reviewing snapshot timing and stake-accounting correctness

## Key Surfaces

- `JBDistributor`: shared round and vesting engine
- `JBTokenDistributor`: ERC-20 distributor using historical `IVotes` reward rounds
- `JB721Distributor`: NFT distributor using tier voting units

## Journey 1: Fund A Distributor

**Actor:** project or payout flow.

**Intent:** move owned assets into a distributor that will vest them over time.

**Preconditions**
- the correct asset and distributor type are chosen
- the distributor actually receives the inventory it is expected to vest

**Main Flow**
1. Fund the distributor directly or through a payout split.
2. Token distributor: the accepted amount is assigned to the current reward round.
3. 721 distributor: the accepted amount is added to the hook's distributable pool.
4. Confirm the tracked balance matches what the distributor received.
5. Use the distributor as the vesting surface, not as the source of entitlement logic.

**Failure Modes**
- wrong asset funded
- underfunded distributor
- caller assumes funding alone starts vesting

**Postconditions**
- token rewards are reserved for the funding round's historical `IVotes` stakers
- 721 rewards are held as inventory for the next vesting snapshot

## Journey 2: Start A Vesting Round

**Actor:** for token rewards, the encoded staker; for 721 rewards, any caller.

**Intent:** materialize rewards into vesting.

**Preconditions**
- the round timing and parameters are valid
- the stake source is usable and non-zero
- token stakers are claiming their own encoded address

**Main Flow**
1. Call `beginVesting`.
2. Token distributor: claim past funded reward rounds through `currentRound - 1` into a fresh vesting entry.
3. 721 distributor: snapshot the relevant balance and stake source for the current round.
4. Vesting entries become claimable over the configured schedule.

**Snapshot timing:** Token-distributor funding records the funding round's snapshot block and total `IVotes` supply. A token staker who claims in round N only starts vesting rewards from rounds `<= N - 1`. The 721 distributor still uses the shared round snapshot flow; `poke` can be used to lock the current and next round snapshots.

**Failure Modes**
- zero total stake or zero historical voting power
- bad deployment parameters such as zero round duration or zero vesting rounds
- stake snapshot is stale or surprising to operators

**Postconditions**
- token distributor: one fresh vesting entry exists for the staker's cumulative past rewards, if any
- 721 distributor: new vesting entries exist with fixed snapshot assumptions

## Journey 3: Collect Vested Rewards

**Actor:** eligible recipient.

**Intent:** collect the share that has unlocked for a round.

**Preconditions**
- the recipient is authorized under the distributor type
- either some share has already vested, or the token recipient has unclaimed past reward rounds to materialize

**Main Flow**
1. Call the relevant claim function.
2. Token distributor first materializes unclaimed past reward rounds into a new vesting entry.
3. The distributor checks authority and unlocked amount.
4. The vested share transfers to the claimant.

**Failure Modes**
- invalid claimant
- claim batch includes invalid 721 token IDs
- reward token transfer fails

**Postconditions**
- vested rewards move to the claimant
- for token rewards, any newly materialized past rewards begin vesting from this claim round

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
