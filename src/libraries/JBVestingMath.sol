// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {mulDiv} from "@prb/math/src/Common.sol";

/// @notice Pure helpers for the distributor's linear vesting arithmetic.
library JBVestingMath {
    /// @notice The share still locked for a vesting entry at `currentRound`.
    /// @dev Mirrors the distributor's existing linear vesting formula. Callers maintain the invariant that
    /// `releaseRound - currentRound <= vestingRounds` whenever `releaseRound > currentRound`.
    /// @param releaseRound The round when the entry is fully unlocked.
    /// @param currentRound The current distributor round.
    /// @param vestingRounds The number of rounds in the vesting period.
    /// @param maxShare The share value representing 100%.
    /// @return lockedShare The share of the entry still locked.
    function lockedShareOf(
        uint256 releaseRound,
        uint256 currentRound,
        uint256 vestingRounds,
        uint256 maxShare
    )
        internal
        pure
        returns (uint256 lockedShare)
    {
        if (releaseRound > currentRound) lockedShare = (releaseRound - currentRound) * maxShare / vestingRounds;
    }

    /// @notice The newly claimable amount for a vesting entry at a locked-share checkpoint.
    /// @param amount The original vesting entry amount.
    /// @param shareClaimed The cumulative share already claimed.
    /// @param lockedShare The share of the entry still locked.
    /// @param maxShare The share value representing 100%.
    /// @return claimAmount The newly unlocked amount.
    /// @return newShareClaimed The cumulative share that should be stored if `claimAmount` is nonzero.
    function newlyClaimableAmountOf(
        uint256 amount,
        uint256 shareClaimed,
        uint256 lockedShare,
        uint256 maxShare
    )
        internal
        pure
        returns (uint256 claimAmount, uint256 newShareClaimed)
    {
        if (lockedShare == 0 && shareClaimed < maxShare) {
            return (unclaimedAmountOf({amount: amount, shareClaimed: shareClaimed, maxShare: maxShare}), maxShare);
        }

        newShareClaimed = maxShare - lockedShare;
        if (newShareClaimed > shareClaimed) {
            claimAmount = mulDiv({x: amount, y: newShareClaimed, denominator: maxShare})
                - mulDiv({x: amount, y: shareClaimed, denominator: maxShare});
        }
    }

    /// @notice The amount remaining after the previously claimed share is deducted.
    /// @dev Computing `amount - paid` releases any floor-division dust on the final unlock.
    /// @param amount The original vesting entry amount.
    /// @param shareClaimed The cumulative share already claimed.
    /// @param maxShare The share value representing 100%.
    /// @return unclaimedAmount The entry amount not yet claimed.
    function unclaimedAmountOf(
        uint256 amount,
        uint256 shareClaimed,
        uint256 maxShare
    )
        internal
        pure
        returns (uint256 unclaimedAmount)
    {
        unclaimedAmount = amount - mulDiv({x: amount, y: shareClaimed, denominator: maxShare});
    }
}
