// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {JBTokenDistributorTest} from "../JBTokenDistributor.t.sol";

/// @notice Proves that a reward round which can never be claimed (zero snapshot `totalStake`, e.g. funded before
/// anyone delegated) is recyclable even when the distributor never expires rounds (`CLAIM_DURATION == 0`). Without the
/// fix, such a round is gated behind `_rewardRoundExpired` (a zero deadline never expires) and its funds are stranded
/// permanently.
contract ZeroStakeRoundRecycleFix is JBTokenDistributorTest {
    function test_zeroStakeNeverExpiringRoundIsRecyclable() public {
        // The default distributor is deployed with CLAIM_DURATION == 0 (rounds never expire).
        assertEq(distributor.CLAIM_DURATION(), 0, "distributor never expires");

        // Fund round 0 with NOBODY delegated, so the snapshot active-vote total is zero -> unclaimable round.
        _fundDistributor(1000 ether);

        (uint256 amount,, uint256 claimedAmount, uint256 claimDeadline, uint256 totalStake) =
            distributor.rewardRoundOf(address(votesToken), 0, IERC20(address(rewardToken)), 0);
        assertEq(amount, 1000 ether, "round funded");
        assertEq(totalStake, 0, "no delegated stake at snapshot -> unclaimable");
        assertEq(claimDeadline, 0, "zero claim duration -> round never expires");
        assertEq(claimedAmount, 0, "round initially unclaimed");

        // Move to a later round so the sweep recycles the funds forward (not into the same round).
        _advanceToRound(2);

        // A permissionless keeper recycles the stranded round despite it never reaching a deadline.
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        uint256 recycled = distributor.recycleExpiredRewards({
            hook: address(votesToken), token: IERC20(address(rewardToken)), rounds: _singleRound(0)
        });
        assertEq(recycled, 1000 ether, "zero-stake never-expiring round was swept, not stranded");

        // The stranded round is marked fully settled and cannot be double-swept.
        (,, claimedAmount,,) = distributor.rewardRoundOf(address(votesToken), 0, IERC20(address(rewardToken)), 0);
        assertEq(claimedAmount, 1000 ether, "stranded round marked fully settled");

        vm.prank(keeper);
        uint256 again = distributor.recycleExpiredRewards({
            hook: address(votesToken), token: IERC20(address(rewardToken)), rounds: _singleRound(0)
        });
        assertEq(again, 0, "no double recycle");
    }

    /// @notice Guardrail: the fix must NOT let a live, claimable round (nonzero stake, not yet expired) be recycled.
    function test_liveStakedRoundStillNotRecyclableBeforeExpiry() public {
        // Give the round real stake so it is claimable (and so the zero-stake bypass does not apply).
        vm.prank(alice);
        votesToken.delegate(alice);
        vm.prank(bob);
        votesToken.delegate(bob);

        // Use a distributor that DOES expire, and fund a round with nonzero stake.
        uint48 claimDuration = 100;
        _fundExpiringDistributor(1000 ether, claimDuration);

        (, , , , uint256 totalStake) =
            distributor.rewardRoundOf(address(votesToken), 0, IERC20(address(rewardToken)), 0);
        assertGt(totalStake, 0, "round has real stake");

        // Before the deadline, recycle must be a no-op for a staked round (claimants still protected).
        _advanceToRound(1);
        uint256 recycled = distributor.recycleExpiredRewards({
            hook: address(votesToken), token: IERC20(address(rewardToken)), rounds: _singleRound(0)
        });
        assertEq(recycled, 0, "staked, unexpired round is not recyclable");
    }
}
