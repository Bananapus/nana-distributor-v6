// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @custom:member hook The stake source whose rewards are being vested.
/// @custom:member groupId The reward group being claimed (0 = legacy all-tiers group).
/// @custom:member tierIds The tier set defining the group (empty for the legacy group); used to filter eligible
/// token IDs on the tier-scoped path.
/// @custom:member token The reward token being vested.
/// @custom:member distributable The reward amount assigned to the round.
/// @custom:member totalStakeAmount The total checkpointed stake sharing the round's rewards.
/// @custom:member vestingReleaseRound The round at which newly materialized rewards finish vesting.
/// @custom:member rewardRound The historical reward round being claimed.
/// @custom:member snapshotBlock The block used for historical stake and ownership lookups.
struct JBVestContext {
    address hook;
    uint256 groupId;
    uint256[] tierIds;
    IERC20 token;
    uint256 distributable;
    uint256 totalStakeAmount;
    uint256 vestingReleaseRound;
    uint256 rewardRound;
    uint256 snapshotBlock;
}
