# User Journeys

## Repo Purpose

This repo distributes already-owned assets over time. Token and 721 rewards are assigned to historical funding rounds and start vesting only when the eligible claimant shows up to claim.

## Primary Actors

- teams funding a distributor from a split or post-mint allocation
- token holders or NFT holders collecting vested rewards
- keepers recycling expired unclaimed reward rounds
- revnet reward claimants borrowing against vesting revnet rewards
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
4. The distributor's immutable claim duration determines whether the funded round expires.
5. Confirm the tracked balance matches what the distributor received.
6. Use the distributor as the vesting surface, not as the source of entitlement logic.

**Round assignment:** If a rewarder sends money to the distributor during round N, that accepted amount is reserved for the historical stakers or NFT owners at round N's snapshot. It does not vest immediately and does not get split among whoever shows up first. It becomes claimable starting in round N + 1, and each eligible claimant can show up later to materialize their own historical share into a vesting entry.

**Expiring rewards:** The claim deadline is measured from the start of round N + 1, when round N first becomes claimable. A zero deployment claim duration means no expiration. Direct funding and split funding use the same immutable duration, so permissionless direct funding cannot choose an incompatible deadline for a shared hook/token/round bucket.

**Failure Modes**
- wrong asset funded
- underfunded distributor
- caller assumes funding alone starts vesting
- deployer sets too short a claim duration and unclaimed rewards become recyclable

**Postconditions**
- rewards are reserved for the funding round's historical stakers or NFT owners
- current-round rewards become claimable only after a later round starts
- expiring reward rounds retain a recyclable unclaimed remainder after their claim deadline

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
4. If a past round has expired, the claim transaction recycles its unclaimed remainder instead of vesting it.
5. Vesting entries become claimable over the configured schedule.

**Snapshot timing:** Funding records the funding round's snapshot block and total stake or `IVotes` supply. A claimant who claims in round N only starts vesting rewards from rounds `<= N - 1`. `poke` can still be used to lock the current and next round snapshots before funding or claims.

**Failure Modes**
- zero total stake or zero historical voting power
- bad deployment parameters such as zero round duration or zero vesting rounds
- stake snapshot is stale or surprising to operators

**Postconditions**
- one fresh vesting entry exists for each claimant/token/reward-token combination with cumulative past rewards, if any
- expired unclaimed rewards recycle into the current reward round and cannot be claimed from the expired round later

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

## Journey 4: Recycle Expired Rewards

**Actor:** any caller.

**Intent:** move expired unclaimed reward inventory into the current reward round.

**Preconditions**
- the distributor was deployed with a nonzero claim duration
- the claim deadline has passed
- some funded amount has not yet started vesting

**Main Flow**
1. Call `burnExpiredRewards` with the hook, reward token, and expired round numbers.
2. The distributor computes each round's unclaimed remainder as funded amount minus amount already materialized into vesting.
3. The expired round is marked settled.
4. The unclaimed remainder is recorded into the current reward round without leaving distributor inventory.

**Failure Modes**
- round is not expired, so nothing recycles
- the whole round has already been claimed into vesting, so nothing recycles
- the distributor was deployed with an unintended claim duration

**Postconditions**
- the expired unclaimed remainder is no longer available through the expired round
- the recycled amount becomes claimable from the current reward round after a later round starts
- already-materialized vesting entries remain intact

## Journey 5: Recycle Rewards For Burned NFTs

**Actor:** caller using the 721 distributor path.

**Intent:** call `releaseForfeitedRewards` to recycle rewards tied to burned NFTs.

**Preconditions**
- the distributor type is 721-based
- the relevant NFTs are burned or otherwise forfeited under the configured rules

**Main Flow**
1. Call `releaseForfeitedRewards`.
2. The distributor reduces current vesting obligations for those forfeited claims.
3. The released value remains in distributor inventory.
4. The released value is recorded into the current reward round.

**Failure Modes**
- caller expects the same behavior from the token distributor
- off-chain systems treat forfeited value as destroyed instead of recycled

**Postconditions**
- forfeited 721 rewards are no longer available to the burned NFT
- forfeited 721 rewards become available through the current reward round after a later round starts

## Journey 6: Borrow Against Vesting Revnet Rewards

**Actor:** eligible token staker or NFT owner.

**Intent:** get source-token liquidity from a revnet while waiting for revnet reward tokens to vest.

**Preconditions**
- the distributor was deployed with a Revnet loans contract and REVOwner
- the distributor has a nonzero vesting period
- the reward token is a JB project token whose project is owned by REVOwner
- exactly one token ID and one reward token are passed
- the caller is authorized to claim that token ID

**Main Flow**
1. Call `borrowAgainstVesting`.
2. The distributor materializes any unclaimed historical rewards for that token ID and reward token.
3. The distributor measures the token ID's remaining uncollected vesting amount.
4. The Revnet loans contract burns that amount from the distributor and opens a loan with the distributor as loan NFT owner.
5. Collection for that token ID and reward token reverts while the loan is outstanding.
6. Call `repayVestingLoan` through the distributor.
7. The distributor repays the Revnet loan, receives the returned collateral, restores it to inventory, and clears the loan lock.
8. The original vesting entries remain unchanged, so the claimant can collect only the amount unlocked by the same schedule that existed before the loan.

**Liquidation Cleanup**
1. If the Revnet loan expires, anyone can liquidate it through Revnet loans.
2. Revnet liquidation permanently destroys the loan collateral and deletes the Revnet loan data.
3. Anyone can call `writeOffLiquidatedVestingLoan` on the distributor with the liquidated loan ID.
4. The distributor verifies the Revnet loan is no longer live, marks the collateralized vesting entries as fully forfeited, and clears the collection lock.
5. Vesting rewards that materialized after the loan was opened remain on their normal vesting schedule.

**Failure Modes**
- caller tries to borrow against more than one token ID or more than one reward token
- the distributor has `VESTING_ROUNDS == 0`, so rewards are immediately collectible instead of loanable
- reward token is not a REVOwner-owned revnet token
- caller tries to repay the loan directly from Revnet loans; the distributor owns the loan NFT
- Revnet loans returns less collateral than was borrowed
- caller tries to write off a loan before Revnet liquidation has deleted it
- caller expects repayment to unlock all collateral immediately

**Postconditions**
- the loan stays custodied by the distributor until repayment
- repayment restores the same vesting schedule instead of bypassing it
- liquidation write-off clears stale locks without releasing or re-minting collateral
- any reward-token excess returned during repayment is sent to the repayer without entering vesting accounting

## Trust Boundaries

- this repo trusts `JBDirectory` for authenticated split-hook caller checks
- `JBTokenDistributor` trusts `IVotes` checkpoints
- `JB721Distributor` trusts the 721 hook's `CHECKPOINTS()` module for historical voting power and the store for tier metadata
- Revnet loan-backed vesting trusts the configured Revnet loans contract to burn and return collateral correctly

## Hand-Offs

- Use the upstream repo that funded the distributor when the question is about why an allocation exists.
- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md) when the stake source is a tiered 721 hook.
