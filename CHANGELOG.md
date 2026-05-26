# Changelog

## Unreleased

- Add distributor-owned Revnet loans for vesting revnet rewards. Claimants can borrow against one token ID's
  uncollected vesting rewards while the distributor keeps the loan NFT, blocks collection, and restores the same
  vesting schedule on repayment.
- Disable vesting loans when `VESTING_ROUNDS == 0`, because those rewards are immediately collectible.
- Depend on `@rev-net/core-v6` for Revnet loan and owner interfaces instead of defining local loan types.
- Add regression tests covering loan custody, direct repayment bypass prevention, active-loan collection locks,
  zero-vesting loan rejection, collateral shortfall reverts, and repayment reward-token excess handling.

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
