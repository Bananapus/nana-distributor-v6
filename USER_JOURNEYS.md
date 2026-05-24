# User Journeys

## Repo Purpose

This repo distributes already-owned assets over time. Token and 721 rewards are assigned to historical funding rounds and start vesting only when the eligible claimant shows up to claim.

## Primary Actors

- teams funding a distributor from a split or post-mint allocation
- token holders or NFT holders collecting vested rewards
- keepers burning expired unclaimed reward rounds
- operators configuring round timing and deployment shape
- auditors reviewing snapshot timing and stake-accounting correctness

## Key Surfaces

- `JBDistributor`: shared round and vesting engine
- `JBTokenDistributor`: ERC-20 distributor using historical `IVotes` reward rounds
- `JB721Distributor`: NFT distributor using historical reward rounds, tier voting units, and owner checkpoints

## Journey 1: Fund A Distributor

**Actor:** project or payout flow.

**Intent:** move owned assets into a distributor that will vest them over time.

**Preconditions**
- the correct asset and distributor type are chosen
- the distributor actually receives the inventory it is expected to vest

**Main Flow**
1. Fund the distributor directly or through a payout split.
2. The accepted amount is assigned to the current reward round for the chosen stake source.
3. The distributor records that round's snapshot block and total checkpointed stake.
4. If direct funding should expire, use `fundWithClaimDuration`; split funding and plain `fund` create non-expiring reward rounds.
5. Confirm the tracked balance matches what the distributor received.
6. Use the distributor as the vesting surface, not as the source of entitlement logic.

**Round assignment:** If a rewarder sends money to the distributor during round N, that accepted amount is reserved for the historical stakers or NFT owners at round N's snapshot. It does not vest immediately and does not get split among whoever shows up first. It becomes claimable starting in round N + 1, and each eligible claimant can show up later to materialize their own historical share into a vesting entry.

**Expiring rewards:** With `fundWithClaimDuration`, the claim deadline is measured from the start of round N + 1, when round N first becomes claimable. A zero duration means no expiration. Fundings merged into the same hook/token/round must use the same deadline.

**Failure Modes**
- wrong asset funded
- underfunded distributor
- caller assumes funding alone starts vesting
- rewarder sets too short a claim duration and unclaimed rewards become burnable

**Postconditions**
- rewards are reserved for the funding round's historical stakers or NFT owners
- current-round rewards become claimable only after a later round starts
- expiring reward rounds retain a burnable unclaimed remainder after their claim deadline

## Journey 2: Start A Vesting Round

**Actor:** for token rewards, the encoded staker; for 721 rewards, the current NFT owner.

**Intent:** materialize rewards into vesting.

**Preconditions**
- the round timing and parameters are valid
- the stake source is usable and non-zero
- token stakers are claiming their own encoded address
- NFT owners are claiming token IDs they currently own

**Main Flow**
1. Call `beginVesting`.
2. Claim past funded reward rounds through `currentRound - 1` into a fresh vesting entry.
3. The distributor uses each funded round's recorded snapshot block and total stake.
4. If a past round has expired, the claim transaction burns its unclaimed remainder instead of vesting it.
5. Vesting entries become claimable over the configured schedule.

**Snapshot timing:** Funding records the funding round's snapshot block and total stake or `IVotes` supply. A claimant who claims in round N only starts vesting rewards from rounds `<= N - 1`. `poke` can still be used to lock the current and next round snapshots before funding or claims.

**Failure Modes**
- zero total stake or zero historical voting power
- bad deployment parameters such as zero round duration or zero vesting rounds
- stake snapshot is stale or surprising to operators

**Postconditions**
- one fresh vesting entry exists for each claimant/token/reward-token combination with cumulative past rewards, if any
- expired unclaimed rewards are settled to the burn sink and cannot be claimed later

## Journey 3: Collect Vested Rewards

**Actor:** eligible recipient.

**Intent:** collect the share that has unlocked for a round.

**Preconditions**
- the recipient is authorized under the distributor type
- either some share has already vested, or the claimant has unclaimed past reward rounds to materialize

**Main Flow**
1. Call the relevant claim function.
2. The distributor first materializes unclaimed past reward rounds into a new vesting entry.
3. The distributor checks authority and unlocked amount.
4. The vested share transfers to the claimant.

**Failure Modes**
- invalid claimant
- claim batch includes invalid 721 token IDs
- reward token transfer fails

**Postconditions**
- vested rewards move to the claimant
- any newly materialized past rewards begin vesting from this claim round

## Journey 4: Burn Expired Rewards

**Actor:** any caller.

**Intent:** clear expired unclaimed reward inventory from the distributor.

**Preconditions**
- the reward round was funded through `fundWithClaimDuration`
- the claim deadline has passed
- some funded amount has not yet started vesting

**Main Flow**
1. Call `burnExpiredRewards` with the hook, reward token, and expired round numbers.
2. The distributor computes each round's unclaimed remainder as funded amount minus amount already materialized into vesting.
3. The unclaimed remainder is removed from tracked distributor inventory.
4. ERC-20 rewards, and native rewards represented by `NATIVE_TOKEN`, are sent to the shared burn sink.

**Failure Modes**
- round is not expired, so nothing burns
- the whole round has already been claimed into vesting, so nothing burns
- same-round funders attempted incompatible deadlines and the later funding reverted

**Postconditions**
- the expired unclaimed remainder is no longer available to late claimants
- already-materialized vesting entries remain intact

## Journey 5: Recycle Forfeited 721 Rewards

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
