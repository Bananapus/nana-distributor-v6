# Changelog

## Unreleased

- Raise dependency floors to the latest published versions; document NatSpec, comment, and lint conventions in
  STYLE_GUIDE.
- Make token distributors with nonzero `CLAIM_DURATION` active-voter distributors. Funded token rounds start with
  `totalStake == 0`; holders call `beginVesting` before the deadline to register snapshot `getPastVotes`, and after
  the deadline only registered voting power shares the pot. Token rounds with no registered voters can be recycled
  into the current round; registered active-voter rounds are protected from permissionless recycling. Deployments with
  `CLAIM_DURATION == 0` keep the non-expiring `getPastTotalSupply` denominator.
- Settle a repaid vesting loan before refunding any native overpayment. `repayVestingLoan` now runs
  `_restoreVestingCollateral` (which deletes the loan record and decrements `totalLoanedVestingAmountOf`) before the
  native `msg.sender.call` refund, following checks-effects-interactions. Previously the refund external call happened
  while the loan record still looked live, so a re-entrant `writeOffLiquidatedVestingLoan(loanId)` could decrement the
  loaned-vesting inventory a first time and let `_restoreVestingCollateral` decrement it a second time, corrupting a
  second loan on the same hook and reward token. The refund amount and recipient are unchanged. Added a regression
  test (`test/regression/VestingLoanNativeRefundSettlement.t.sol`).
- Add tier-scoped reward groups. Every reward, vesting, and loan record carries a generic `groupId` dimension in the
  base `JBDistributor`: `groupId == 0` is the default pool, acted on by the plain (no-`tierIds`) signatures. The base
  is tier-agnostic — the tier concept lives in `JB721Distributor`, where a non-zero group is
  `keccak256(abi.encode(tierIds))` for a strictly-increasing tier set (group 0 = all tiers). `JB721Distributor` adds
  `tierIds` overloads of `fund`, `beginVesting`, `collectVestedRewards`, `borrowAgainstVesting`, `recycleExpiredRewards`,
  and `releaseForfeitedRewards` (plus `claimedFor`/`collectableFor` views and a `tierIdsOf` view) that fund and claim
  pots only holders of the given tiers can claim, pro-rata by tier `votingUnits` against a summed
  `getPastTierVotingUnits` denominator (no per-owner cap on the tier path; the all-tiers path uses the per-owner cap).
  Split funding via `processSplitWith` always lands in group 0. `JBTokenDistributor` exposes no tier API and threads
  `groupId` only for storage isolation; non-expiring token rounds use global `getPastTotalSupply`, while active-voter
  token rounds use registered `getPastVotes`. Re-keyed the public state getters (`rewardRoundOf`, `vestingDataOf`,
  `latestVestedIndexOf`, `activeVestingLoanIdOf`, `nextClaimRoundOf`) with
  `groupId` as their 2nd argument, added a `groupId` field to the `Claimed`/`Collected` events, and a `groupId` member
  to the `JBVestingLoan` struct. Requires `@bananapus/721-hook-v6 >= 0.0.63` for `getPastTierVotingUnits`.
- Add distributor-owned Revnet loans for vesting revnet rewards. Claimants can borrow against one token ID's
  uncollected vesting rewards while the distributor keeps the loan NFT, blocks collection, and restores the same
  vesting schedule on repayment.
- Disable vesting loans when `VESTING_ROUNDS == 0`, because those rewards are immediately collectible.
- Depend on `@rev-net/core-v6` for Revnet loan and owner interfaces instead of defining local loan types.
- Add regression tests covering loan custody, direct repayment bypass prevention, active-loan collection locks,
  zero-vesting loan rejection, collateral shortfall reverts, and repayment reward-token excess handling.
- Lift the shared `beginVesting`/`collectVestedRewards` entrypoints into the base `JBDistributor` (they dispatch
  into each concrete distributor's `_claimPastRewards`/`_requireCanClaimTokenIds`), removing the duplicated
  overrides in `JBTokenDistributor` and `JB721Distributor`. Delete the dead snapshot-balance model entirely —
  `_vestTokenIds`/`_vestSingleToken`, `_takeSnapshotOf`, the `snapshotAtRoundOf` view, the `JBTokenSnapshotData`
  struct, the `_snapshotAtRoundOf`/`_snapshotInitializedFor` mappings, the `SnapshotCreated` event, and the
  `JBDistributor_NothingToDistribute` error are gone. No live behavior change: rewards remain recorded per round
  and lazily claimed via the round-ledger path.

## 0.0.16 — Bump v6 deps to nana-core-v6 0.0.53 cohort

- `@bananapus/core-v6`: `^0.0.48 → ^0.0.53` ([PR #145](https://github.com/Bananapus/nana-core-v6/pull/145)).
- `@bananapus/721-hook-v6`: `^0.0.47 → ^0.0.50`.
- `@bananapus/permission-ids-v6`: `^0.0.22 → ^0.0.25`.
- All `JBRulesetMetadata` test literals patched to include `pauseCrossProjectFeeFreeInflows: false`.

## 0.0.1

Initial release of the Juicebox V6 distributor system.

### Features

- **JBDistributor**: Abstract base contract with round-based distribution and configurable linear vesting.
- **JBTokenDistributor**: Singleton distributor for IVotes-compatible ERC-20 tokens. Stake weight = delegated voting power at round start.
- **JB721Distributor**: Singleton distributor for JB 721 NFT holders. Stake weight = tier's `votingUnits`. Burned NFTs excluded from stake; forfeited rewards recyclable through the current reward round.
- Both implement `IJBSplitHook` for direct integration with Juicebox payout splits.
- Linear vesting over configurable number of rounds.
- Fee-on-transfer token support via balance-delta pattern.
- Native ETH distribution support.
