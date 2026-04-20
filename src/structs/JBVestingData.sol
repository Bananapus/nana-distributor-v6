// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member releaseRound The round at which the vesting tokens are fully released.
/// @custom:member amount The original amount of tokens that were claimed.
/// @custom:member shareClaimed The share of the amount that has already been claimed (out of `MAX_SHARE`).
struct JBVestingData {
    uint256 releaseRound;
    uint256 amount;
    uint256 shareClaimed;
}
