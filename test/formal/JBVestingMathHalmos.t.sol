// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {mulDiv} from "@prb/math/src/Common.sol";

import {JBVestingMath} from "../../src/libraries/JBVestingMath.sol";

/// @notice Halmos smoke proofs for the distributor's shared linear-vesting arithmetic.
contract JBVestingMathHalmos {
    /// @notice The distributor's 100% share denominator.
    uint256 internal constant _MAX_SHARE = 100_000;

    /// @notice Checks representative claim amounts never exceed the unclaimed amount.
    /// @dev This boundary table keeps the expensive `mulDiv` equivalence path out of Halmos' symbolic solver.
    function check_claimNeverExceedsUnclaimedBoundaryTable() public pure {
        (uint256 partialClaim,) = JBVestingMath.newlyClaimableAmountOf({
            amount: 7, shareClaimed: 20_000, lockedShare: 50_000, maxShare: _MAX_SHARE
        });
        uint256 partialUnclaimed =
            JBVestingMath.unclaimedAmountOf({amount: 7, shareClaimed: 20_000, maxShare: _MAX_SHARE});

        assert(partialClaim <= partialUnclaimed);

        (uint256 finalClaim,) = JBVestingMath.newlyClaimableAmountOf({
            amount: 7, shareClaimed: 90_000, lockedShare: 0, maxShare: _MAX_SHARE
        });
        uint256 finalUnclaimed =
            JBVestingMath.unclaimedAmountOf({amount: 7, shareClaimed: 90_000, maxShare: _MAX_SHARE});

        assert(finalClaim <= finalUnclaimed);
    }

    /// @notice Checks the final unlock releases exactly the remaining dust-inclusive amount.
    /// @dev Uses an amount that creates division dust so the final-claim branch is covered directly.
    function check_finalUnlockPaysRemainingBoundaryTable() public pure {
        (uint256 claimAmount, uint256 newShareClaimed) = JBVestingMath.newlyClaimableAmountOf({
            amount: 7, shareClaimed: 90_000, lockedShare: 0, maxShare: _MAX_SHARE
        });
        uint256 expectedRemaining =
            JBVestingMath.unclaimedAmountOf({amount: 7, shareClaimed: 90_000, maxShare: _MAX_SHARE});

        assert(claimAmount == expectedRemaining);
        assert(newShareClaimed == _MAX_SHARE);
    }

    /// @notice Checks the round-to-locked-share formula at vesting boundaries.
    function check_lockedShareBoundaryTable() public pure {
        assert(
            JBVestingMath.lockedShareOf({releaseRound: 10, currentRound: 6, vestingRounds: 4, maxShare: _MAX_SHARE})
                == _MAX_SHARE
        );
        assert(
            JBVestingMath.lockedShareOf({releaseRound: 10, currentRound: 8, vestingRounds: 4, maxShare: _MAX_SHARE})
                == _MAX_SHARE / 2
        );
        assert(
            JBVestingMath.lockedShareOf({releaseRound: 10, currentRound: 9, vestingRounds: 4, maxShare: _MAX_SHARE})
                == _MAX_SHARE / 4
        );
        assert(
            JBVestingMath.lockedShareOf({releaseRound: 10, currentRound: 10, vestingRounds: 4, maxShare: _MAX_SHARE})
                == 0
        );
        assert(
            JBVestingMath.lockedShareOf({releaseRound: 10, currentRound: 11, vestingRounds: 4, maxShare: _MAX_SHARE})
                == 0
        );
    }

    /// @notice Proves no amount is claimable if the locked share has not crossed a new cumulative share.
    /// @param amount The original vesting amount.
    /// @param shareClaimed The cumulative share already claimed.
    /// @param lockedShare The share still locked.
    function check_noClaimBeforeNextShare(uint32 amount, uint32 shareClaimed, uint32 lockedShare) public pure {
        if (shareClaimed > _MAX_SHARE || lockedShare > _MAX_SHARE || lockedShare == 0) return;
        if (_MAX_SHARE - uint256(lockedShare) > shareClaimed) return;

        (uint256 claimAmount,) = JBVestingMath.newlyClaimableAmountOf({
            amount: uint256(amount), shareClaimed: shareClaimed, lockedShare: lockedShare, maxShare: _MAX_SHARE
        });

        assert(claimAmount == 0);
    }

    /// @notice Proves partial unlocks match the delta between cumulative rounded claims.
    /// @param amount The original vesting amount.
    /// @param shareClaimed The cumulative share already claimed.
    /// @param lockedShare The share still locked.
    function check_partialUnlockUsesCumulativeDelta(
        uint32 amount,
        uint32 shareClaimed,
        uint32 lockedShare
    )
        public
        pure
    {
        if (shareClaimed > _MAX_SHARE || lockedShare > _MAX_SHARE || lockedShare == 0) return;

        uint256 expectedNewShare = _MAX_SHARE - uint256(lockedShare);
        if (expectedNewShare <= shareClaimed) return;

        (uint256 claimAmount, uint256 newShareClaimed) = JBVestingMath.newlyClaimableAmountOf({
            amount: uint256(amount), shareClaimed: shareClaimed, lockedShare: lockedShare, maxShare: _MAX_SHARE
        });

        uint256 paidAtNew = mulDiv({x: uint256(amount), y: expectedNewShare, denominator: _MAX_SHARE});
        uint256 paidBefore = mulDiv({x: uint256(amount), y: shareClaimed, denominator: _MAX_SHARE});

        assert(claimAmount == paidAtNew - paidBefore);
        assert(newShareClaimed == expectedNewShare);
    }
}
