// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBTokenDistributor} from "../src/JBTokenDistributor.sol";
import {JBDistributor} from "../src/JBDistributor.sol";
import {IJBTokenDistributor} from "../src/interfaces/IJBTokenDistributor.sol";

/// @notice Mock JB directory for testing.
contract MockDirectory {
    mapping(uint256 projectId => mapping(address terminal => bool)) public terminals;
    mapping(uint256 projectId => address controller) public controllers;

    function setTerminal(uint256 projectId, address terminal, bool isTerminal) external {
        terminals[projectId][terminal] = isTerminal;
    }

    function setController(uint256 projectId, address controller) external {
        controllers[projectId] = controller;
    }

    function isTerminalOf(uint256 projectId, IJBTerminal terminal) external view returns (bool) {
        return terminals[projectId][address(terminal)];
    }

    function controllerOf(uint256 projectId) external view returns (IERC165) {
        return IERC165(controllers[projectId]);
    }
}

/// @notice Simple ERC20 token for reward payouts.
contract MockRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice ERC20Votes token for staking (mock for JBERC20).
contract MockVotesToken is ERC20, ERC20Votes {
    constructor() ERC20("StakeToken", "STK") EIP712("StakeToken", "1") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}

contract JBTokenDistributorTest is Test {
    MockDirectory directory;
    MockRewardToken rewardToken;
    MockVotesToken votesToken;
    JBTokenDistributor distributor;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address terminal = makeAddr("terminal");
    uint256 projectId = 1;

    // 100 seconds per round, 4 vesting rounds.
    uint256 constant ROUND_DURATION = 100;
    uint256 constant VESTING_ROUNDS = 4;

    function setUp() public {
        directory = new MockDirectory();
        rewardToken = new MockRewardToken();
        votesToken = new MockVotesToken();

        directory.setTerminal(projectId, terminal, true);

        distributor = new JBTokenDistributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS, 0);

        // Mint staking tokens.
        votesToken.mint(alice, 700 ether);
        votesToken.mint(bob, 300 ether);
    }

    //*********************************************************************//
    // ----------------------------- helpers ----------------------------- //
    //*********************************************************************//

    /// @notice Encode a staker address as a tokenId.
    function _tokenId(address staker) internal pure returns (uint256) {
        return uint256(uint160(staker));
    }

    /// @notice Advance to 1 second after the start of the given round, and advance block number too.
    function _advanceToRound(uint256 round) internal {
        uint256 targetTimestamp = distributor.roundStartTimestamp(round) + 1;
        // Test helper only moves time forward to the requested round boundary.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < targetTimestamp) {
            vm.warp(targetTimestamp);
        }
        // Also advance block number so getPastVotes works with past blocks.
        vm.roll(block.number + 1);
    }

    /// @notice Fund the distributor via the direct `fund` method.
    function _fundDistributor(uint256 amount) internal {
        vm.roll(block.number + 1);
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), amount);
    }

    /// @notice Fund a distributor deployed with a nonzero claim duration for expiry tests.
    function _fundExpiringDistributor(uint256 amount, uint48 claimDuration) internal {
        if (distributor.CLAIM_DURATION() != claimDuration) {
            distributor =
                new JBTokenDistributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS, claimDuration);
        }

        vm.roll(block.number + 1);
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), amount);
    }

    function _splitContext(address token, uint256 amount) internal view returns (JBSplitHookContext memory) {
        return JBSplitHookContext({
            token: token,
            amount: amount,
            decimals: 18,
            projectId: projectId,
            groupId: 0,
            split: JBSplit({
                percent: 1_000_000_000,
                projectId: 0,
                beneficiary: payable(address(votesToken)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(distributor))
            })
        });
    }

    //*********************************************************************//
    // ----------------------------- tests ------------------------------ //
    //*********************************************************************//

    function test_happyPath_fundVestCollect() public {
        // Alice delegates to self.
        vm.prank(alice);
        votesToken.delegate(alice);

        // Bob delegates to self.
        vm.prank(bob);
        votesToken.delegate(bob);

        // Fund the distributor with 1000 reward tokens.
        _fundDistributor(1000 ether);

        // Advance to round 1 (so snapshot block is in the past for getPastVotes).
        _advanceToRound(1);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // Alice and Bob each start vesting their own historical rewards.
        _beginVestingFor(alice, tokens);
        _beginVestingFor(bob, tokens);

        // Alice should have 700/1000 = 70% = 700 tokens claimed.
        uint256 aliceClaimed =
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        assertEq(aliceClaimed, 700 ether, "Alice should have 700 claimed");

        // Bob should have 300/1000 = 30% = 300 tokens claimed.
        uint256 bobClaimed = distributor.claimedFor(address(votesToken), _tokenId(bob), IERC20(address(rewardToken)));
        assertEq(bobClaimed, 300 ether, "Bob should have 300 claimed");

        // Advance past full vesting (4 rounds).
        _advanceToRound(1 + VESTING_ROUNDS);

        // Alice collects.
        vm.prank(alice);
        distributor.collectVestedRewards(address(votesToken), _singleTokenId(alice), tokens, alice);
        assertEq(rewardToken.balanceOf(alice), 700 ether, "Alice should receive 700 tokens");

        // Bob collects.
        vm.prank(bob);
        distributor.collectVestedRewards(address(votesToken), _singleTokenId(bob), tokens, bob);
        assertEq(rewardToken.balanceOf(bob), 300 ether, "Bob should receive 300 tokens");
    }

    function test_noDelegation_zeroAllocation() public {
        // Alice does NOT delegate — should get 0 voting power.
        // Bob delegates to self.
        vm.prank(bob);
        votesToken.delegate(bob);

        _fundDistributor(1000 ether);
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = _tokenId(alice);
        tokenIds[1] = _tokenId(bob);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        vm.prank(alice);
        distributor.beginVesting(address(votesToken), _singleTokenId(alice), tokens);

        vm.prank(bob);
        distributor.beginVesting(address(votesToken), _singleTokenId(bob), tokens);

        // Alice has 0 claimed (no delegation = 0 votes).
        uint256 aliceClaimed =
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        assertEq(aliceClaimed, 0, "Alice should have 0 claimed without delegation");

        // Bob gets all rewards because total supply includes all tokens but alice has 0 votes.
        // getPastVotes(bob) = 300, getPastTotalSupply = 1000 (includes undelegated).
        // So bob gets 300/1000 * 1000 = 300.
        uint256 bobClaimed = distributor.claimedFor(address(votesToken), _tokenId(bob), IERC20(address(rewardToken)));
        assertEq(bobClaimed, 300 ether, "Bob should have 300 claimed (his share of total supply)");
    }

    function test_nonDelegatedSupply_staysInPool() public {
        // Only bob delegates. Total supply = 1000, bob votes = 300.
        // Bob gets 300/1000 = 30%. The other 70% stays in the pool.
        vm.prank(bob);
        votesToken.delegate(bob);

        _fundDistributor(1000 ether);
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(bob);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _beginVestingFor(bob, tokens);

        uint256 bobClaimed = distributor.claimedFor(address(votesToken), _tokenId(bob), IERC20(address(rewardToken)));
        assertEq(bobClaimed, 300 ether, "Bob gets 30% of pool");

        // 700 tokens remain undistributed in the pool.
        uint256 totalVesting = distributor.totalVestingAmountOf(address(votesToken), IERC20(address(rewardToken)));
        assertEq(totalVesting, 300 ether, "Only 300 vesting");
        uint256 balance = distributor.balanceOf(address(votesToken), IERC20(address(rewardToken)));
        assertEq(balance, 1000 ether, "Full balance still held");
    }

    function test_twoStakers_proRataByVotingPower() public {
        // Alice: 700, Bob: 300. Both delegate to self.
        vm.prank(alice);
        votesToken.delegate(alice);
        vm.prank(bob);
        votesToken.delegate(bob);

        _fundDistributor(1000 ether);
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = _tokenId(alice);
        tokenIds[1] = _tokenId(bob);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _beginVestingFor(alice, tokens);
        _beginVestingFor(bob, tokens);

        uint256 aliceClaimed =
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        uint256 bobClaimed = distributor.claimedFor(address(votesToken), _tokenId(bob), IERC20(address(rewardToken)));

        assertEq(aliceClaimed, 700 ether, "Alice gets 70%");
        assertEq(bobClaimed, 300 ether, "Bob gets 30%");
    }

    function test_processSplitWith_onlyAuthorized() public {
        JBSplitHookContext memory context = _splitContext(address(rewardToken), 100 ether);

        // Unauthorized caller should revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBTokenDistributor.JBTokenDistributor_Unauthorized.selector, projectId, address(this)
            )
        );
        distributor.processSplitWith(context);

        // Authorized terminal should succeed.
        rewardToken.mint(terminal, 100 ether);
        vm.startPrank(terminal);
        rewardToken.approve(address(distributor), 100 ether);
        distributor.processSplitWith(context);
        vm.stopPrank();

        assertEq(
            distributor.balanceOf(address(votesToken), IERC20(address(rewardToken))),
            100 ether,
            "Balance credited after processSplitWith"
        );
    }

    function test_processSplitWith_afterDirectDustFundingUsesFixedClaimDuration() public {
        uint48 claimDuration = 50;
        uint256 splitAmount = 100 ether;

        distributor =
            new JBTokenDistributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS, claimDuration);

        rewardToken.mint(carol, 1);
        vm.startPrank(carol);
        rewardToken.approve(address(distributor), 1);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), 1);
        vm.stopPrank();

        rewardToken.mint(terminal, splitAmount);
        vm.startPrank(terminal);
        rewardToken.approve(address(distributor), splitAmount);
        distributor.processSplitWith(_splitContext(address(rewardToken), splitAmount));
        vm.stopPrank();

        (uint256 amount,,, uint256 deadline,) =
            distributor.rewardRoundOf(address(votesToken), IERC20(address(rewardToken)), 0);

        assertEq(amount, splitAmount + 1, "dust and split funding share one bucket");
        assertEq(deadline, distributor.roundStartTimestamp(1) + claimDuration, "deadline is contract-fixed");
    }

    function test_releaseForfeitedRewards_alwaysReverts() public {
        // _tokenBurned always returns false, so releaseForfeitedRewards should always revert.
        vm.prank(alice);
        votesToken.delegate(alice);

        _fundDistributor(1000 ether);
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(alice);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _beginVestingFor(alice, tokens);

        // Attempt to release forfeited rewards — should revert with NoAccess.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBDistributor.JBDistributor_NoAccess.selector, address(votesToken), _tokenId(alice), address(this)
            )
        );
        distributor.releaseForfeitedRewards(address(votesToken), tokenIds, tokens, alice);
    }

    function test_multiRoundVesting() public {
        vm.prank(alice);
        votesToken.delegate(alice);
        vm.prank(bob);
        votesToken.delegate(bob);

        _fundDistributor(1000 ether);
        _advanceToRound(1);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // Begin vesting in round 1.
        _beginVestingFor(alice, tokens);
        _beginVestingFor(bob, tokens);

        // After 2 of 4 vesting rounds, 50% should be collectable.
        _advanceToRound(3);

        uint256 aliceCollectable =
            distributor.collectableFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        // Alice claimed 700 ether, 50% vested = 350.
        assertEq(aliceCollectable, 350 ether, "Alice should have 50% collectable after 2/4 rounds");

        // Collect partial.
        vm.prank(alice);
        distributor.collectVestedRewards(address(votesToken), _singleTokenId(alice), tokens, alice);
        assertEq(rewardToken.balanceOf(alice), 350 ether, "Alice collected 350");

        // Fund more for the current reward round, then let that round close.
        _fundDistributor(500 ether);
        _advanceToRound(4);

        // Begin vesting the newly closed reward round.
        _beginVestingFor(alice, tokens);
        _beginVestingFor(bob, tokens);

        // Advance past both vesting periods (entry 0 releases at round 5, entry 1 at round 8).
        _advanceToRound(1 + VESTING_ROUNDS + VESTING_ROUNDS);

        // Collect all remaining.
        vm.prank(alice);
        distributor.collectVestedRewards(address(votesToken), _singleTokenId(alice), tokens, alice);

        vm.prank(bob);
        distributor.collectVestedRewards(address(votesToken), _singleTokenId(bob), tokens, bob);

        // Alice: 700 (round 1) + 350 (70% of 500 from round 3) = 1050.
        assertEq(rewardToken.balanceOf(alice), 1050 ether, "Alice total after multi-round");
        // Bob: 300 (round 1) + 150 (30% of 500 from round 3) = 450.
        assertEq(rewardToken.balanceOf(bob), 450 ether, "Bob total after multi-round");
    }

    function test_cannotCollectOtherStakersRewards() public {
        vm.prank(alice);
        votesToken.delegate(alice);

        _fundDistributor(1000 ether);
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(alice);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _beginVestingFor(alice, tokens);

        _advanceToRound(1 + VESTING_ROUNDS);

        // Bob tries to collect Alice's rewards — should revert.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBDistributor.JBDistributor_NoAccess.selector, address(votesToken), _tokenId(alice), bob
            )
        );
        distributor.collectVestedRewards(address(votesToken), _singleTokenId(alice), tokens, bob);
    }

    function test_supportsInterface() public view {
        assertTrue(distributor.supportsInterface(type(IJBTokenDistributor).interfaceId), "IJBTokenDistributor");
        assertTrue(distributor.supportsInterface(type(IJBSplitHook).interfaceId), "IJBSplitHook");
        assertTrue(distributor.supportsInterface(type(IERC165).interfaceId), "IERC165");
    }

    function test_partialVesting_linearUnlock() public {
        vm.prank(alice);
        votesToken.delegate(alice);

        _fundDistributor(1000 ether);
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(alice);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _beginVestingFor(alice, tokens);

        // After 1 of 4 rounds, 25% should be collectable.
        _advanceToRound(2);
        uint256 collectable =
            distributor.collectableFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        // Alice has 700 (70% of 1000). 25% of 700 = 175.
        assertEq(collectable, 175 ether, "25% vested after 1/4 rounds");

        // After 3 of 4 rounds, 75% should be collectable.
        _advanceToRound(4);
        collectable = distributor.collectableFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        assertEq(collectable, 525 ether, "75% vested after 3/4 rounds");
    }

    function test_autoVest_collectWithoutBeginVesting() public {
        // Alice delegates to self.
        vm.prank(alice);
        votesToken.delegate(alice);

        // Fund the distributor.
        _fundDistributor(1000 ether);

        // Advance to round 1.
        _advanceToRound(1);

        // Advance past full vesting WITHOUT calling beginVesting first.
        _advanceToRound(1 + VESTING_ROUNDS);

        // Alice calls collectVestedRewards directly — auto-vest should kick in.
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        vm.prank(alice);
        distributor.collectVestedRewards(address(votesToken), _singleTokenId(alice), tokens, alice);

        // Alice should have auto-vested for the current round (1 + VESTING_ROUNDS).
        // Her claimed amount depends on what round the auto-vest captures.
        // The auto-vest happens at the current round, so it creates a new vesting entry for that round.
        // Since it's a new vesting entry, it won't be fully vested yet (just started).
        // But previous rounds' funds accumulated and the collect at the current round auto-vests them.
        uint256 aliceClaimed =
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        assertGt(aliceClaimed, 0, "Alice should have auto-vested something");
    }

    function test_delayedClaim_cumulativeRewardsStartVestingWhenClaimed() public {
        vm.prank(alice);
        votesToken.delegate(alice);
        vm.prank(bob);
        votesToken.delegate(bob);

        // Round 0 reward.
        _fundDistributor(1000 ether);

        // Round 1 reward.
        _advanceToRound(1);
        _fundDistributor(500 ether);

        // Alice waits until round 3 before claiming anything.
        _advanceToRound(3);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _beginVestingFor(alice, tokens);

        uint256 aliceClaimed =
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        assertEq(aliceClaimed, 1050 ether, "Alice claims all past rounds cumulatively");

        uint256 aliceCollectable =
            distributor.collectableFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        assertEq(aliceCollectable, 0, "Delayed rewards start vesting when claimed");

        _advanceToRound(3 + VESTING_ROUNDS);

        vm.prank(alice);
        distributor.collectVestedRewards(address(votesToken), _singleTokenId(alice), tokens, alice);
        assertEq(rewardToken.balanceOf(alice), 1050 ether, "Alice collects after claim-time vesting elapses");
    }

    function test_currentRoundRewardsExcludedUntilNextRound() public {
        vm.prank(alice);
        votesToken.delegate(alice);
        vm.prank(bob);
        votesToken.delegate(bob);

        // Round 0 reward.
        _fundDistributor(1000 ether);

        _advanceToRound(1);

        // Round 1 reward should not be claimable until round 2.
        _fundDistributor(500 ether);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _beginVestingFor(alice, tokens);

        uint256 aliceClaimed =
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        assertEq(aliceClaimed, 700 ether, "Current round reward is excluded");

        _advanceToRound(2);
        _beginVestingFor(alice, tokens);

        aliceClaimed = distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        assertEq(aliceClaimed, 1050 ether, "Prior round reward becomes claimable next round");
    }

    function test_expiringRewards_claimBeforeDeadlineStartsVesting() public {
        vm.prank(alice);
        votesToken.delegate(alice);
        vm.prank(bob);
        votesToken.delegate(bob);

        uint48 claimDuration = 50;
        _fundExpiringDistributor(1000 ether, claimDuration);

        (uint256 amount,, uint256 claimedAmount, uint256 claimDeadline, uint256 totalStake) =
            distributor.rewardRoundOf(address(votesToken), IERC20(address(rewardToken)), 0);
        assertEq(amount, 1000 ether, "round funded amount");
        assertEq(claimedAmount, 0, "nothing claimed yet");
        assertEq(claimDeadline, distributor.roundStartTimestamp(1) + claimDuration, "deadline starts at claimable");
        assertEq(totalStake, 1000 ether, "snapshot total stake");

        _advanceToRound(1);
        _beginVestingFor(alice, _singleRewardToken());

        uint256 aliceClaimed =
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        assertEq(aliceClaimed, 700 ether, "Alice claims before expiry");

        (,, claimedAmount,,) = distributor.rewardRoundOf(address(votesToken), IERC20(address(rewardToken)), 0);
        assertEq(claimedAmount, 700 ether, "claimed amount tracks materialized vesting");
    }

    function test_expiringRewards_permissionlessBurnAfterDeadline() public {
        vm.prank(alice);
        votesToken.delegate(alice);
        vm.prank(bob);
        votesToken.delegate(bob);

        uint48 claimDuration = 10;
        _fundExpiringDistributor(1000 ether, claimDuration);

        vm.warp(distributor.roundStartTimestamp(1) + claimDuration);
        vm.roll(block.number + 1);

        vm.prank(carol);
        uint256 burned = distributor.burnExpiredRewards({
            hook: address(votesToken), token: IERC20(address(rewardToken)), rounds: _singleRound(0)
        });

        assertEq(burned, 1000 ether, "all unclaimed rewards burn");
        assertEq(distributor.balanceOf(address(votesToken), IERC20(address(rewardToken))), 0, "pool balance burns");
        assertEq(rewardToken.balanceOf(distributor.BURN_ADDRESS()), 1000 ether, "burn sink receives expired rewards");

        _beginVestingFor(alice, _singleRewardToken());

        uint256 aliceClaimed =
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        assertEq(aliceClaimed, 0, "late claim gets no expired rewards");
    }

    function test_expiringNativeRewards_permissionlessBurnAfterDeadline() public {
        uint48 claimDuration = 10;
        IERC20 nativeToken = IERC20(JBConstants.NATIVE_TOKEN);

        distributor =
            new JBTokenDistributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS, claimDuration);

        distributor.fund{value: 1 ether}(address(votesToken), nativeToken, 0);

        vm.warp(distributor.roundStartTimestamp(1) + claimDuration);
        vm.roll(block.number + 1);

        uint256 burnSinkBalanceBefore = distributor.BURN_ADDRESS().balance;

        vm.prank(carol);
        uint256 burned =
            distributor.burnExpiredRewards({hook: address(votesToken), token: nativeToken, rounds: _singleRound(0)});

        assertEq(burned, 1 ether, "native reward burns");
        assertEq(distributor.balanceOf(address(votesToken), nativeToken), 0, "native pool balance burns");
        assertEq(address(distributor).balance, 0, "native inventory leaves distributor");
        assertEq(distributor.BURN_ADDRESS().balance - burnSinkBalanceBefore, 1 ether, "burn sink receives native");
    }

    function test_expiringRewards_partialClaimThenBurnsOnlyRemainder() public {
        vm.prank(alice);
        votesToken.delegate(alice);
        vm.prank(bob);
        votesToken.delegate(bob);

        uint48 claimDuration = 50;
        _fundExpiringDistributor(1000 ether, claimDuration);

        _advanceToRound(1);
        _beginVestingFor(alice, _singleRewardToken());

        vm.warp(distributor.roundStartTimestamp(1) + claimDuration);
        vm.roll(block.number + 1);

        vm.prank(carol);
        uint256 burned = distributor.burnExpiredRewards({
            hook: address(votesToken), token: IERC20(address(rewardToken)), rounds: _singleRound(0)
        });

        assertEq(burned, 300 ether, "only Bob's unclaimed share burns");
        assertEq(
            distributor.balanceOf(address(votesToken), IERC20(address(rewardToken))),
            700 ether,
            "vested inventory remains"
        );
        assertEq(rewardToken.balanceOf(distributor.BURN_ADDRESS()), 300 ether, "burn sink receives remainder");

        _beginVestingFor(bob, _singleRewardToken());
        uint256 bobClaimed = distributor.claimedFor(address(votesToken), _tokenId(bob), IERC20(address(rewardToken)));
        assertEq(bobClaimed, 0, "Bob cannot claim after the remainder burns");
    }

    function test_expiringRewards_lateClaimBurnsExpiredRound() public {
        vm.prank(alice);
        votesToken.delegate(alice);
        vm.prank(bob);
        votesToken.delegate(bob);

        uint48 claimDuration = 10;
        _fundExpiringDistributor(1000 ether, claimDuration);

        vm.warp(distributor.roundStartTimestamp(1) + claimDuration);
        vm.roll(block.number + 1);

        _beginVestingFor(alice, _singleRewardToken());

        uint256 aliceClaimed =
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        assertEq(aliceClaimed, 0, "expired rewards do not vest");
        assertEq(distributor.balanceOf(address(votesToken), IERC20(address(rewardToken))), 0, "late claim burns pool");
        assertEq(rewardToken.balanceOf(distributor.BURN_ADDRESS()), 1000 ether, "late claim sends rewards to burn sink");
    }

    function test_poke_recordsSnapshotBlock() public {
        _advanceToRound(1);

        uint256 expectedBlock = block.number - 1;
        distributor.poke();

        assertEq(distributor.roundSnapshotBlock(1), expectedBlock, "Snapshot block should be block.number - 1");
    }

    function test_poke_idempotent() public {
        _advanceToRound(1);

        distributor.poke();
        uint256 firstSnapshot = distributor.roundSnapshotBlock(1);

        // Advance block but stay in same round.
        vm.roll(block.number + 10);

        distributor.poke();
        uint256 secondSnapshot = distributor.roundSnapshotBlock(1);

        assertEq(firstSnapshot, secondSnapshot, "Poke should be idempotent within a round");
    }

    function test_skipAlreadyVested_noRevert() public {
        vm.prank(alice);
        votesToken.delegate(alice);

        _fundDistributor(1000 ether);
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(alice);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // First vest.
        _beginVestingFor(alice, tokens);

        // Second vest in same round should NOT revert (skips silently).
        _beginVestingFor(alice, tokens);

        // Only one vesting entry should exist.
        uint256 claimed = distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        assertEq(claimed, 700 ether, "Should have exactly one vesting entry worth 700");
    }

    //*********************************************************************//
    // ----------------------------- internal ---------------------------- //
    //*********************************************************************//

    function _singleTokenId(address staker) internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(staker);
    }

    function _singleRound(uint256 round) internal pure returns (uint256[] memory rounds) {
        rounds = new uint256[](1);
        rounds[0] = round;
    }

    function _singleRewardToken() internal view returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));
    }

    function _beginVestingFor(address staker, IERC20[] memory tokens) internal {
        vm.prank(staker);
        distributor.beginVesting(address(votesToken), _singleTokenId(staker), tokens);
    }

    /// @notice Once a round's snapshot has been taken — even at a zero balance — it must not be overwritten by
    /// later activity in the same round. Otherwise mid-round deposits can leak into the current round's allocation.
    /// @dev This guards the `_takeSnapshotOf` write-once invariant. The bug surfaces through
    /// `collectVestedRewards`, which calls `_takeSnapshotOf` even when there is nothing distributable.
    function test_zeroBalanceSnapshot_isStickyWithinRound() public {
        // Alice has stake and delegates to self.
        vm.prank(alice);
        votesToken.delegate(alice);

        // Move to round 1 (snapshot block must be strictly in the past for getPastVotes).
        _advanceToRound(1);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // Round 1, distributor balance is zero. Alice calls collectVestedRewards, which writes
        // a `{balance: 0, vestingAmount: 0}` snapshot for (votesToken, rewardToken, round=1).
        vm.prank(alice);
        distributor.collectVestedRewards(address(votesToken), _singleTokenId(alice), tokens, alice);

        uint256 aliceClaimedBefore =
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        assertEq(aliceClaimedBefore, 0, "no allocation when balance is zero");

        // Mid-round funding: 1000 reward tokens land in the distributor AFTER the snapshot was taken.
        // These tokens belong to round 2's reward pool, not round 1.
        _fundDistributor(1000 ether);

        // Alice calls collectVestedRewards again, still in round 1.
        vm.prank(alice);
        distributor.collectVestedRewards(address(votesToken), _singleTokenId(alice), tokens, alice);

        uint256 aliceClaimedAfter =
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));

        // Sticky snapshot invariant: the round's snapshot was already taken at zero balance, so the
        // newly funded 1000 must NOT be allocated within round 1.
        assertEq(
            aliceClaimedAfter,
            aliceClaimedBefore,
            "post-snapshot mid-round deposits must not leak into the current round"
        );
    }
}
