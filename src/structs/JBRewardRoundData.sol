// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A reward amount assigned to a specific token-distributor round.
/// @custom:member amount The reward amount assigned to the round.
/// @custom:member totalStake The aggregate stake at the round's snapshot block.
/// @custom:member snapshotBlock The block used for per-account historical stake lookups.
/// @custom:member initialized Whether the round has a fixed snapshot.
struct JBRewardRoundData {
    uint256 amount;
    uint256 totalStake;
    uint256 snapshotBlock;
    bool initialized;
}
