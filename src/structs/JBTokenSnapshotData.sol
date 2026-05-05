// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A point-in-time snapshot of a reward token's state for a specific hook and round. The distributable
/// amount for the round is `balance - vestingAmount`.
/// @custom:member balance The total token balance held for the hook's stakers at snapshot time.
/// @custom:member vestingAmount The amount currently locked in vesting at snapshot time (not yet distributable).
struct JBTokenSnapshotData {
    uint256 balance;
    uint256 vestingAmount;
}
