// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member hook The stake source whose historical rewards are being claimed.
/// @custom:member groupId The reward group being claimed (0 = legacy all-tiers group).
/// @custom:member tierIds The tier set defining the group (empty for the legacy group); used to filter eligible
/// token IDs on the tier-scoped path.
/// @custom:member lastClaimableRound The last completed reward round included in the claim.
/// @custom:member vestingReleaseRound The round at which newly materialized rewards finish vesting.
struct JBClaimContext {
    address hook;
    uint256 groupId;
    uint256[] tierIds;
    uint256 lastClaimableRound;
    uint256 vestingReleaseRound;
}
