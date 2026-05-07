// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {JBTokenDistributor} from "../../src/JBTokenDistributor.sol";
import {JB721Distributor} from "../../src/JB721Distributor.sol";
import {JBDistributor} from "../../src/JBDistributor.sol";

import {
    VotingCapMockDirectory,
    VotingCapMockHook,
    VotingCapMockRewardToken,
    VotingCapMockStore,
    VotingCapMockCheckpoints
} from "./VotingPowerCapRegression.t.sol";

// =========================================================================
// Mock contracts for JBTokenDistributor tests ()
// =========================================================================

/// @notice Mock JB directory for distributor regression tests.
contract DistributorMockDirectory {
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

/// @notice Simple ERC20 reward token for distributor regression tests.
contract DistributorMockRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice ERC20Votes token for staking in distributor regression tests.
contract DistributorMockVotesToken is ERC20, ERC20Votes {
    constructor() ERC20("StakeToken", "STK") EIP712("StakeToken", "1") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}

// =========================================================================
// Test contract
// =========================================================================

/// @notice Tests for distributor regression fixes.
contract DistributorRegressionFixesTest is Test {
    // --- Token Distributor setup () ---
    DistributorMockDirectory tokenDirectory;
    DistributorMockRewardToken rewardToken;
    DistributorMockVotesToken votesToken;
    JBTokenDistributor tokenDistributor;

    // --- 721 Distributor setup () ---
    VotingCapMockStore store;
    VotingCapMockHook hook;
    VotingCapMockDirectory nftDirectory;
    VotingCapMockRewardToken nftRewardToken;
    JB721Distributor nftDistributor;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address controller = makeAddr("controller");
    address terminal = makeAddr("terminal");
    uint256 projectId = 1;

    uint256 constant ROUND_DURATION = 100;
    uint256 constant VESTING_ROUNDS = 4;

    function setUp() public {
        // --- Token Distributor ---
        tokenDirectory = new DistributorMockDirectory();
        rewardToken = new DistributorMockRewardToken();
        votesToken = new DistributorMockVotesToken();

        tokenDirectory.setTerminal(projectId, terminal, true);
        tokenDirectory.setController(projectId, controller);

        tokenDistributor = new JBTokenDistributor(IJBDirectory(address(tokenDirectory)), ROUND_DURATION, VESTING_ROUNDS);

        votesToken.mint(alice, 1000 ether);
        vm.prank(alice);
        votesToken.delegate(alice);

        // --- 721 Distributor ---
        store = new VotingCapMockStore();
        hook = new VotingCapMockHook(store);
        nftDirectory = new VotingCapMockDirectory();

        nftDistributor = new JB721Distributor(IJBDirectory(address(nftDirectory)), ROUND_DURATION, VESTING_ROUNDS);

        nftDirectory.setTerminal(projectId, address(this), true);

        nftRewardToken = new VotingCapMockRewardToken();

        JB721TierFlags memory flags;

        // Tier 1: votingUnits = 50 each, 3 minted out of 10.
        store.setMaxTierIdOf(1);
        store.setTier(
            1,
            JB721Tier({
                id: 1,
                price: 1 ether,
                remainingSupply: 7,
                initialSupply: 10,
                votingUnits: 50,
                reserveFrequency: 0,
                reserveBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                category: 0,
                discountPercent: 0,
                flags: flags,
                splitPercent: 0,
                resolvedUri: ""
            })
        );

        // Alice owns 3 NFTs: tokens 1, 2, 3 — all tier 1 (50 voting units each).
        store.setTokenTier(1, 1);
        store.setTokenTier(2, 1);
        store.setTokenTier(3, 1);
        hook.setOwner(1, alice);
        hook.setOwner(2, alice);
        hook.setOwner(3, alice);
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _advanceToRound(uint256 round, JBDistributor dist) internal {
        uint256 targetTimestamp = dist.roundStartTimestamp(round) + 1;
        // Test helper only moves time forward to the requested round boundary.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < targetTimestamp) {
            vm.warp(targetTimestamp);
        }
        vm.roll(block.number + 1);
    }

    function _buildTokenContext(address token, uint256 amount) internal view returns (JBSplitHookContext memory) {
        JBSplit memory split = JBSplit({
            percent: 1_000_000_000,
            projectId: 0,
            beneficiary: payable(address(votesToken)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(tokenDistributor))
        });

        return JBSplitHookContext({
            token: token, amount: amount, decimals: 18, projectId: projectId, groupId: 0, split: split
        });
    }

    // =====================================================================
    // Unbacked split credits
    // =====================================================================

    /// @notice A controller calls processSplitWith without transferring tokens first.
    ///         Should revert with JBDistributor_UnfundedSplitCredit.
    function test_C6_fix_reverts_unfunded_credit() public {
        uint256 amount = 500 ether;
        JBSplitHookContext memory context = _buildTokenContext(address(rewardToken), amount);

        // Controller calls processSplitWith WITHOUT transferring any tokens to the distributor.
        // The controller has no allowance either, so it falls into the "else" (controller-prepaid) branch.
        vm.prank(controller);
        vm.expectRevert(JBDistributor.JBDistributor_UnfundedSplitCredit.selector);
        tokenDistributor.processSplitWith(context);

        // Verify no balance was credited.
        assertEq(
            tokenDistributor.balanceOf(address(votesToken), IERC20(address(rewardToken))),
            0,
            "No balance should be credited without actual token transfer"
        );
    }

    /// @notice A controller that actually transfers tokens before calling processSplitWith
    ///         should still work correctly.
    function test_C6_legitimate_prepaid_still_works() public {
        uint256 amount = 500 ether;
        JBSplitHookContext memory context = _buildTokenContext(address(rewardToken), amount);

        // Controller transfers tokens to the distributor first.
        rewardToken.mint(controller, amount);
        vm.prank(controller);
        require(rewardToken.transfer(address(tokenDistributor), amount));

        // Now the controller calls processSplitWith — should succeed because the unaccounted
        // balance covers the declared amount.
        vm.prank(controller);
        tokenDistributor.processSplitWith(context);

        // Verify balance was credited.
        assertEq(
            tokenDistributor.balanceOf(address(votesToken), IERC20(address(rewardToken))),
            amount,
            "Balance should be credited when tokens were actually transferred"
        );

        // Verify the tokens are held by the distributor.
        assertEq(rewardToken.balanceOf(address(tokenDistributor)), amount, "Tokens should be in the distributor");
    }

    // =====================================================================
    // Voting cap reset across calls
    // =====================================================================

    /// @notice Calling beginVesting multiple times in the same round for the same owner's
    ///         different tokens should not reset the voting power cap.
    function test_H24_fix_caps_across_calls() public {
        // Alice has 3 NFTs x 50 voting units = 150 total.
        // Her pastVotes is only 100 — so she should be capped at 100 total.
        hook._checkpoints().setVotesOverride(alice, 100);

        // Fund with 1500 ether. Total stake = 150 (3 minted * 50 voting units).
        nftRewardToken.mint(address(this), 1500 ether);
        nftRewardToken.approve(address(nftDistributor), 1500 ether);
        nftDistributor.fund(address(hook), IERC20(address(nftRewardToken)), 1500 ether);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(nftRewardToken));

        // Call beginVesting THREE TIMES, each with a single token ID.
        // Without the fix, each call resets the consumed voting power to 0,
        // allowing Alice to claim 50 voting units per call = 150 total (bypassing the 100 cap).
        // With the fix, consumed votes persist in storage across calls.
        uint256[] memory singleId = new uint256[](1);

        singleId[0] = 1;
        nftDistributor.beginVesting(address(hook), singleId, tokens);

        singleId[0] = 2;
        nftDistributor.beginVesting(address(hook), singleId, tokens);

        singleId[0] = 3;
        nftDistributor.beginVesting(address(hook), singleId, tokens);

        // Check claimed amounts.
        uint256 claimed1 = nftDistributor.claimedFor(address(hook), 1, IERC20(address(nftRewardToken)));
        uint256 claimed2 = nftDistributor.claimedFor(address(hook), 2, IERC20(address(nftRewardToken)));
        uint256 claimed3 = nftDistributor.claimedFor(address(hook), 3, IERC20(address(nftRewardToken)));

        uint256 totalClaimed = claimed1 + claimed2 + claimed3;

        // With cap enforced: Alice has 100 pastVotes out of 150 total stake.
        // NFT 1: effective stake = min(50, 100 remaining) = 50, reward = 1500 * 50/150 = 500
        // NFT 2: effective stake = min(50, 50 remaining) = 50, reward = 1500 * 50/150 = 500
        // NFT 3: effective stake = min(50, 0 remaining) = 0, reward = 0
        // Total = 1000 ether (not 1500).
        assertEq(claimed1, 500 ether, "NFT 1 should get full 50-unit share");
        assertEq(claimed2, 500 ether, "NFT 2 should get full 50-unit share");
        assertEq(claimed3, 0, "NFT 3 should get 0 (voting power exhausted across calls)");
        assertEq(totalClaimed, 1000 ether, "Total should be capped at 100/150 of distributable");
    }

    // =====================================================================
    // fund() ETH trap
    // =====================================================================

    /// @notice Sending ETH with an ERC-20 token in fund() should revert.
    function test_unexpectedEthReverts() public {
        uint256 erc20Amount = 100 ether;
        rewardToken.mint(address(this), erc20Amount);
        rewardToken.approve(address(tokenDistributor), erc20Amount);

        // Call fund() with an ERC-20 token but also send msg.value.
        // This should revert with JBDistributor_UnexpectedNativeValue.
        vm.expectRevert(JBDistributor.JBDistributor_UnexpectedNativeValue.selector);
        tokenDistributor.fund{value: 1 ether}(address(votesToken), IERC20(address(rewardToken)), erc20Amount);
    }

    /// @notice fund() with native token and msg.value should still work normally.
    function test_fundNativeTokenStillWorks() public {
        vm.deal(address(this), 5 ether);

        tokenDistributor.fund{value: 5 ether}(
            address(votesToken),
            IERC20(JBConstants.NATIVE_TOKEN),
            0 // amount param is ignored for native token
        );

        assertEq(
            tokenDistributor.balanceOf(address(votesToken), IERC20(JBConstants.NATIVE_TOKEN)),
            5 ether,
            "Native ETH fund should work normally"
        );
    }

    /// @notice fund() with ERC-20 and no ETH should still work normally.
    function test_fundErc20WithoutEthStillWorks() public {
        uint256 amount = 200 ether;
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(tokenDistributor), amount);

        tokenDistributor.fund(address(votesToken), IERC20(address(rewardToken)), amount);

        assertEq(
            tokenDistributor.balanceOf(address(votesToken), IERC20(address(rewardToken))),
            amount,
            "ERC-20 fund without ETH should work normally"
        );
    }
}
