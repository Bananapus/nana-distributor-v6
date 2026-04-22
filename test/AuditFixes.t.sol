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
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBTokenDistributor} from "../src/JBTokenDistributor.sol";
import {JBDistributor} from "../src/JBDistributor.sol";
import {IJBTokenDistributor} from "../src/interfaces/IJBTokenDistributor.sol";

/// @notice Mock JB directory for audit fix tests.
contract AuditFixMockDirectory {
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
contract AuditFixMockRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice ERC20Votes token for staking.
contract AuditFixMockVotesToken is ERC20, ERC20Votes {
    constructor() ERC20("StakeToken", "STK") EIP712("StakeToken", "1") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}

/// @notice Tests for controller-prepaid split funds, zero-stake vesting, and empty claim array handling in
/// JBTokenDistributor / JBDistributor.
contract AuditFixesTest is Test {
    AuditFixMockDirectory directory;
    AuditFixMockRewardToken rewardToken;
    AuditFixMockVotesToken votesToken;
    JBTokenDistributor distributor;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address terminal = makeAddr("terminal");
    address controller = makeAddr("controller");
    uint256 projectId = 1;

    uint256 constant ROUND_DURATION = 100;
    uint256 constant VESTING_ROUNDS = 4;

    function setUp() public {
        directory = new AuditFixMockDirectory();
        rewardToken = new AuditFixMockRewardToken();
        votesToken = new AuditFixMockVotesToken();

        directory.setTerminal(projectId, terminal, true);
        directory.setController(projectId, controller);

        distributor = new JBTokenDistributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);

        // Mint staking tokens and delegate.
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

    /// @notice Advance to 1 second after the start of the given round.
    function _advanceToRound(uint256 round) internal {
        uint256 targetTimestamp = distributor.roundStartTimestamp(round) + 1;
        if (block.timestamp < targetTimestamp) {
            vm.warp(targetTimestamp);
        }
        vm.roll(block.number + 1);
    }

    /// @notice Build a JBSplitHookContext for the given token and amount.
    function _buildContext(address token, uint256 amount) internal view returns (JBSplitHookContext memory) {
        JBSplit memory split = JBSplit({
            percent: 1_000_000_000,
            projectId: 0,
            beneficiary: payable(address(votesToken)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(distributor))
        });

        return JBSplitHookContext({
            token: token, amount: amount, decimals: 18, projectId: projectId, groupId: 0, split: split
        });
    }

    //*********************************************************************//
    // ------- Controller-Prepaid ERC20 Split Funds ---------------------- //
    //*********************************************************************//

    /// @notice Terminal path: ERC20 credited via allowance + transferFrom.
    function test_controllerPrepaidSplits_processSplitWith_terminalPath_creditsViaAllowance() public {
        uint256 amount = 500 ether;
        JBSplitHookContext memory context = _buildContext(address(rewardToken), amount);

        // Terminal mints tokens and approves the distributor before calling.
        rewardToken.mint(terminal, amount);
        vm.startPrank(terminal);
        rewardToken.approve(address(distributor), amount);
        distributor.processSplitWith(context);
        vm.stopPrank();

        // Balance should be credited.
        assertEq(
            distributor.balanceOf(address(votesToken), IERC20(address(rewardToken))),
            amount,
            "Terminal path: balance should be credited via transferFrom"
        );
        // Tokens should be held by the distributor.
        assertEq(rewardToken.balanceOf(address(distributor)), amount, "Tokens should be in the distributor");
    }

    /// @notice Controller-prepaid path: ERC20 credited when tokens are sent before processSplitWith.
    function test_controllerPrepaidSplits_processSplitWith_controllerPrepaidPath_creditsDirectly() public {
        uint256 amount = 500 ether;
        JBSplitHookContext memory context = _buildContext(address(rewardToken), amount);

        // Controller transfers tokens directly to the distributor (no approval).
        rewardToken.mint(controller, amount);
        vm.prank(controller);
        rewardToken.transfer(address(distributor), amount);

        // Controller calls processSplitWith WITHOUT granting an allowance.
        vm.prank(controller);
        distributor.processSplitWith(context);

        // Balance should be credited via the controller-prepaid path.
        assertEq(
            distributor.balanceOf(address(votesToken), IERC20(address(rewardToken))),
            amount,
            "Controller-prepaid path: balance should be credited directly"
        );
    }

    /// @notice Verifies that the controller-prepaid path allows end-to-end vesting and collection.
    function test_controllerPrepaidSplits_controllerPrepaidPath_endToEndVestAndCollect() public {
        uint256 amount = 1000 ether;

        // Alice delegates to self so she has voting power.
        vm.prank(alice);
        votesToken.delegate(alice);
        vm.prank(bob);
        votesToken.delegate(bob);

        // Controller sends tokens directly and calls processSplitWith.
        JBSplitHookContext memory context = _buildContext(address(rewardToken), amount);
        rewardToken.mint(controller, amount);
        vm.prank(controller);
        rewardToken.transfer(address(distributor), amount);
        vm.prank(controller);
        distributor.processSplitWith(context);

        // Advance to round 1 and begin vesting.
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = _tokenId(alice);
        tokenIds[1] = _tokenId(bob);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // Advance past full vesting.
        _advanceToRound(1 + VESTING_ROUNDS);

        // Alice collects her 70%.
        uint256[] memory aliceIds = new uint256[](1);
        aliceIds[0] = _tokenId(alice);
        vm.prank(alice);
        distributor.collectVestedRewards(address(votesToken), aliceIds, tokens, alice);
        assertEq(rewardToken.balanceOf(alice), 700 ether, "Alice should collect 70% of controller-prepaid funds");

        // Bob collects his 30%.
        uint256[] memory bobIds = new uint256[](1);
        bobIds[0] = _tokenId(bob);
        vm.prank(bob);
        distributor.collectVestedRewards(address(votesToken), bobIds, tokens, bob);
        assertEq(rewardToken.balanceOf(bob), 300 ether, "Bob should collect 30% of controller-prepaid funds");
    }

    //*********************************************************************//
    // ------- Zero totalStake Causes beginVesting Revert ---------------- //
    //*********************************************************************//

    /// @notice beginVesting with zero totalStake should silently return (no revert).
    function test_zeroTotalStake_beginVesting_zeroTotalStake_doesNotRevert() public {
        // Nobody delegates, so getPastTotalSupply will return 0. But we use the mock votes token
        // which returns totalSupply via getPastTotalSupply. We need to ensure totalSupply is 0.
        // Since votesToken was minted in setUp but nobody delegated, getPastTotalSupply returns
        // the total supply of delegated votes. With no delegation, this is 0 for ERC20Votes.

        // Fund the distributor.
        rewardToken.mint(address(this), 1000 ether);
        rewardToken.approve(address(distributor), 1000 ether);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), 1000 ether);

        // Advance to round 1.
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(alice);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // Should NOT revert even though totalStake == 0. Funds carry over.
        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // No vesting should have occurred.
        assertEq(
            distributor.totalVestingAmountOf(address(votesToken), IERC20(address(rewardToken))),
            0,
            "Nothing should be vesting when totalStake is zero"
        );

        // Balance should still be intact for future rounds.
        assertEq(
            distributor.balanceOf(address(votesToken), IERC20(address(rewardToken))),
            1000 ether,
            "Funds should carry over when totalStake is zero"
        );
    }

    /// @notice After zero-stake round passes, a round with stakers should distribute normally.
    function test_zeroTotalStake_zeroTotalStake_fundsCarryOverToNextRound() public {
        // Fund the distributor.
        rewardToken.mint(address(this), 1000 ether);
        rewardToken.approve(address(distributor), 1000 ether);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), 1000 ether);

        // Round 1: no one has delegated — zero total stake.
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(alice);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // beginVesting with zero stake — silently returns. H-25: eagerly locks round 2 snapshot.
        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // Alice delegates (after round 2 snapshot is already locked by H-25 eager fix).
        vm.prank(alice);
        votesToken.delegate(alice);

        // Round 2: Alice's delegation not captured (round 2 snapshot precedes her delegation).
        // Zero stake again — silently returns. H-25: eagerly locks round 3 snapshot (AFTER delegation).
        _advanceToRound(2);
        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // Round 3: Alice IS eligible (round 3 snapshot was set after her delegation).
        // Funds from rounds 1 and 2 carry over since no vesting was recorded.
        _advanceToRound(3);
        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // Alice should have claimed her share of the full 1000 ether (700/1000 total supply).
        uint256 aliceClaimed =
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        assertEq(aliceClaimed, 700 ether, "Alice should claim 70% of carried-over funds");
    }

    //*********************************************************************//
    // ------- Empty Claim Arrays Freeze Round Snapshot ------------------ //
    //*********************************************************************//

    /// @notice beginVesting with empty tokenIds should revert.
    function test_emptyClaimArrays_beginVesting_emptyTokenIds_reverts() public {
        uint256[] memory tokenIds = new uint256[](0);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        vm.expectRevert(JBDistributor.JBDistributor_EmptyTokenIds.selector);
        distributor.beginVesting(address(votesToken), tokenIds, tokens);
    }

    /// @notice collectVestedRewards with empty tokenIds should revert.
    function test_emptyClaimArrays_collectVestedRewards_emptyTokenIds_reverts() public {
        uint256[] memory tokenIds = new uint256[](0);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        vm.expectRevert(JBDistributor.JBDistributor_EmptyTokenIds.selector);
        distributor.collectVestedRewards(address(votesToken), tokenIds, tokens, alice);
    }

    /// @notice Empty tokenIds should not cause a snapshot to be recorded.
    function test_emptyClaimArrays_emptyTokenIds_doesNotFreezeSnapshot() public {
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](0);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // beginVesting reverts before _ensureSnapshotBlock is called.
        vm.expectRevert(JBDistributor.JBDistributor_EmptyTokenIds.selector);
        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // No snapshot should have been recorded.
        assertEq(distributor.roundSnapshotBlock(1), 0, "Snapshot should not be recorded after empty-array revert");
    }

    //*********************************************************************//
    // ------- H-25: Eager Snapshot --------------------------------------- //
    //*********************************************************************//

    /// @notice Calling poke() in round N should eagerly set the snapshot for round N+1.
    function test_h25_pokeEagerlySetsFutureSnapshot() public {
        // Advance to round 1.
        _advanceToRound(1);

        // poke() in round 1 should set snapshot for round 1 AND eagerly set round 2.
        distributor.poke();

        assertGt(distributor.roundSnapshotBlock(1), 0, "Round 1 snapshot should be set");
        assertGt(distributor.roundSnapshotBlock(2), 0, "Round 2 snapshot should be eagerly set by poke()");
    }

    /// @notice beginVesting locks the next round's snapshot. A later call in round N+1
    /// should use that same snapshot, not overwrite it with a fresher block.
    function test_h25_lateJoinerCannotManipulateSnapshot() public {
        // Alice delegates to self so she has voting power.
        vm.prank(alice);
        votesToken.delegate(alice);

        // Fund the distributor.
        rewardToken.mint(address(this), 1000 ether);
        rewardToken.approve(address(distributor), 1000 ether);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), 1000 ether);

        // Advance to round 1 and call beginVesting — this locks round 1 AND eagerly locks round 2 snapshot.
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(alice);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // Record the eagerly-set round 2 snapshot.
        uint256 eagerSnapshot = distributor.roundSnapshotBlock(2);
        assertGt(eagerSnapshot, 0, "Round 2 snapshot should be eagerly set");

        // Advance many blocks (simulating a late joiner trying to push the snapshot forward).
        vm.roll(block.number + 100);

        // Advance to round 2.
        _advanceToRound(2);

        // Fund more so beginVesting has something to distribute.
        rewardToken.mint(address(this), 500 ether);
        rewardToken.approve(address(distributor), 500 ether);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), 500 ether);

        // beginVesting in round 2 should NOT overwrite the eagerly-set snapshot.
        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        assertEq(
            distributor.roundSnapshotBlock(2),
            eagerSnapshot,
            "Late joiner should not overwrite eagerly-set round 2 snapshot"
        );
    }

    /// @notice Calling poke() twice in the same round should not change the next round's snapshot.
    function test_h25_eagerSnapshotIdempotent() public {
        // Advance to round 1.
        _advanceToRound(1);

        // First poke sets round 1 and eagerly sets round 2 snapshot.
        distributor.poke();
        uint256 firstEagerSnapshot = distributor.roundSnapshotBlock(2);
        assertGt(firstEagerSnapshot, 0, "Round 2 snapshot should be set after first poke");

        // Advance some blocks within round 1.
        vm.roll(block.number + 50);

        // Second poke in the same round should NOT change the round 2 snapshot.
        distributor.poke();
        uint256 secondEagerSnapshot = distributor.roundSnapshotBlock(2);

        assertEq(firstEagerSnapshot, secondEagerSnapshot, "Eager snapshot should be idempotent across multiple pokes");
    }
}
