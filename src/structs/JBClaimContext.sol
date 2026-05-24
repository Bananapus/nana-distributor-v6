// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member hook The stake source whose historical rewards are being claimed.
/// @custom:member lastClaimableRound The last completed reward round included in the claim.
/// @custom:member vestingReleaseRound The round at which newly materialized rewards finish vesting.
struct JBClaimContext {
    address hook;
    uint256 lastClaimableRound;
    uint256 vestingReleaseRound;
}
