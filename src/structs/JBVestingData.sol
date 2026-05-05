// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Tracks a single vesting entry for a staker token ID. Tokens vest linearly from the claim round to
/// `releaseRound`, and `shareClaimed` tracks how much has been collected so far (out of `MAX_SHARE = 100,000`).
/// @custom:member releaseRound The round at which the tokens are fully vested and 100% claimable.
/// @custom:member amount The original amount of reward tokens that were claimed (before any collection).
/// @custom:member shareClaimed The cumulative share collected so far (out of `MAX_SHARE`). Increases each
/// time `collectVestedRewards` is called.
struct JBVestingData {
    uint256 releaseRound;
    uint256 amount;
    uint256 shareClaimed;
}
