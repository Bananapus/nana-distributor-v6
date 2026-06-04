# V5 to V6 Changelog

## Scope

This is a V5-to-V6 migration changelog, not a package release log or commit history. `nana-distributor-v6` has no deployed V5 package counterpart in `../../v5/evm`; it is a new V6 contract package.

## Current V6 Surface

- `JBDistributor`
- `JB721Distributor`
- `JBTokenDistributor`
- `IJBDistributor`
- `IJB721Distributor`
- `IJBTokenDistributor`
- vesting, claim, reward-round, and loan structs under `src/structs`

## Summary

- V6 introduces distributor contracts for vesting and reward distribution flows that did not exist as a deployed V5 package.
- `JB721Distributor` distributes rewards to 721 holders using token or tier inputs and historical voting/unit snapshots.
- `JBTokenDistributor` distributes rewards for token-based contexts and enforces expected token/native payment inputs.
- Distributor flows include claim, collect, recycle, vesting-loan, and liquidation/write-off event surface that V5 integrators will not have indexed before.

## ABI, Event, and Error Changes

- No V5 ABI exists to diff against. All distributor ABIs are new to V6.
- New functions to integrate include distributor funding, claim/collect views, tier ID views, and vesting/reward claim operations from the V6 interfaces.
- New events include:
  - `BorrowAgainstVesting`
  - `Claimed`
  - `Collected`
  - `RoundSnapshotRecorded`
  - `ExpiredRewardsRecycled`
  - `ForfeitedRewardsRecycled`
  - `LiquidatedVestingLoanWrittenOff`
  - `RepayVestingLoan`
- New custom errors include:
  - `JB721Distributor_TierIdsNotIncreasing`
  - `JB721Distributor_TokenIdsNotIncreasing`
  - `JB721Distributor_TokenMismatch`
  - `JBTokenDistributor_InvalidTokenId`
  - `JBTokenDistributor_TokenMismatch`
  - native amount mismatch and unauthorized errors on both distributor variants.

## Machine-Checked ABI Coverage

Generated from Foundry `out/**/*.json` artifacts, filtered to this repo's own runtime source roots and excluding tests, scripts, and dependencies.

- V5 comparison package: none; this is a new V6 runtime ABI surface.
- Own-source ABI artifacts compared: V6 `7`, V5 `0`.
- Contract/interface coverage: `7` added, `0` removed, `0` shared names with ABI changes, `0` shared names ABI-identical.
- Shared-name ABI item deltas: `0` added, `0` removed, `0` modified.

Added V6 ABI artifacts:
- `IJB721Distributor` from `src/interfaces/IJB721Distributor.sol`: `38` functions, `8` events, `0` errors.
- `IJBDistributor` from `src/interfaces/IJBDistributor.sol`: `26` functions, `8` events, `0` errors.
- `IJBTokenDistributor` from `src/interfaces/IJBTokenDistributor.sol`: `29` functions, `8` events, `0` errors.
- `JB721Distributor` from `src/JB721Distributor.sol`: `43` functions, `8` events, `27` errors.
- `JBDistributor` from `src/JBDistributor.sol`: `30` functions, `8` events, `22` errors.
- `JBTokenDistributor` from `src/JBTokenDistributor.sol`: `34` functions, `8` events, `26` errors.
- `JBVestingMath` from `src/libraries/JBVestingMath.sol`: `0` functions, `0` events, `0` errors.

Generated event/error name deltas:
- Event names added:
  - `BorrowAgainstVesting`, `Claimed`, `Collected`, `ExpiredRewardsRecycled`, `ForfeitedRewardsRecycled`, `LiquidatedVestingLoanWrittenOff`, `RepayVestingLoan`, `RoundSnapshotRecorded`.
- Error names added:
  - `JB721Distributor_NativeAmountMismatch`, `JB721Distributor_TierIdsNotIncreasing`, `JB721Distributor_TokenIdsNotIncreasing`, `JB721Distributor_TokenMismatch`, `JB721Distributor_Unauthorized`, `JBDistributor_EmptyTokenIds`, `JBDistributor_InsufficientRepaidCollateral`, `JBDistributor_InsufficientRepayAmount`.
  - `JBDistributor_InvalidRoundDuration`, `JBDistributor_InvalidVestingLoanId`, `JBDistributor_NativeTransferFailed`, `JBDistributor_NoAccess`, `JBDistributor_NoVestingLoan`, `JBDistributor_NotRevnetRewardToken`, `JBDistributor_NothingToBorrow`, `JBDistributor_ReentrantTokenTransfer`.
  - `JBDistributor_RevnetLoansNotConfigured`, `JBDistributor_Uint208Overflow`, `JBDistributor_Uint48Overflow`, `JBDistributor_UnexpectedNativeValue`, `JBDistributor_UnexpectedRepayAmount`, `JBDistributor_UnexpectedTokenCount`, `JBDistributor_VestingLoanNotLiquidated`, `JBDistributor_VestingLoanOutstanding`.
  - `JBDistributor_VestingLoansDisabled`, `JBTokenDistributor_InvalidTokenId`, `JBTokenDistributor_NativeAmountMismatch`, `JBTokenDistributor_TokenMismatch`, `JBTokenDistributor_Unauthorized`, `PRBMath_MulDiv_Overflow`, `SafeERC20FailedOperation`.

## Migration Notes

- Treat distributor indexing as a new V6 subsystem, not a V5 upgrade.
- Regenerate ABIs directly from V6 and design event schemas around the new reward, vesting, and loan lifecycle events.
- When integrating with 721 rewards, use V6 721 hook checkpoint surfaces rather than current-owner-only assumptions.
