// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A reward amount assigned to a specific distributor round.
/// @custom:member amount The reward amount assigned to the round.
/// @custom:member snapshotBlock The block used for per-account historical stake lookups.
/// @custom:member claimedAmount The reward amount already materialized into vesting.
/// @custom:member claimDeadline The timestamp at which unclaimed rewards can be burned. Zero means no expiration.
/// @custom:member totalStake The aggregate stake at the round's snapshot block.
struct JBRewardRoundData {
    uint208 amount;
    uint48 snapshotBlock;
    uint208 claimedAmount;
    uint48 claimDeadline;
    uint208 totalStake;
}
