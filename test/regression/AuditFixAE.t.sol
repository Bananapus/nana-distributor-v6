// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";

import {JBDistributor} from "../../src/JBDistributor.sol";
import {JBTokenDistributor} from "../../src/JBTokenDistributor.sol";
import {JB721Distributor} from "../../src/JB721Distributor.sol";

// =========================================================================
// Mock contracts
// =========================================================================

contract AEDirectory {
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

contract AERewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract AEVotesToken is ERC20, ERC20Votes {
    constructor() ERC20("StakeToken", "STK") EIP712("StakeToken", "1") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}

// =========================================================================
// AE-1: Stale ERC-20 sweep in processSplitWith
// =========================================================================

contract AuditFixAE1Test is Test {
    AEDirectory internal directory;
    AERewardToken internal rewardToken;
    AEVotesToken internal votesToken;
    JBTokenDistributor internal distributor;

    address internal alice = makeAddr("alice");
    address internal controllerA = makeAddr("controllerA");
    address internal controllerB = makeAddr("controllerB");
    address internal terminal = makeAddr("terminal");
    uint256 internal constant PROJECT_A = 1;
    uint256 internal constant PROJECT_B = 2;
    uint256 internal constant ROUND_DURATION = 100;
    uint256 internal constant VESTING_ROUNDS = 4;

    function setUp() public {
        directory = new AEDirectory();
        rewardToken = new AERewardToken();
        votesToken = new AEVotesToken();

        directory.setTerminal(PROJECT_A, terminal, true);
        directory.setController(PROJECT_A, controllerA);
        directory.setController(PROJECT_B, controllerB);

        distributor = new JBTokenDistributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);
    }

    function _buildContext(
        uint256 projectId,
        address token,
        uint256 amount
    )
        internal
        view
        returns (JBSplitHookContext memory)
    {
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

    /// @notice Stray ERC-20 transfers can no longer satisfy a controller's processSplitWith call.
    function test_AE1_strayTransferCannotBeSwepted() public {
        // Simulate a stray transfer (e.g., accidental send or another controller's prepay).
        rewardToken.mint(address(this), 1000 ether);
        rewardToken.transfer(address(distributor), 1000 ether);

        JBSplitHookContext memory ctx = _buildContext(PROJECT_A, address(rewardToken), 1000 ether);

        // Controller A tries to claim the stray tokens. Without allowance, it reverts.
        vm.prank(controllerA);
        vm.expectRevert();
        distributor.processSplitWith(ctx);

        // No balance was credited.
        assertEq(
            distributor.balanceOf(address(votesToken), IERC20(address(rewardToken))),
            0,
            "Stray transfer should not be capturable"
        );
    }

    /// @notice Controller with proper allowance succeeds.
    function test_AE1_controllerWithAllowanceSucceeds() public {
        uint256 amount = 500 ether;
        JBSplitHookContext memory ctx = _buildContext(PROJECT_A, address(rewardToken), amount);

        rewardToken.mint(controllerA, amount);
        vm.startPrank(controllerA);
        rewardToken.approve(address(distributor), amount);
        distributor.processSplitWith(ctx);
        vm.stopPrank();

        assertEq(
            distributor.balanceOf(address(votesToken), IERC20(address(rewardToken))),
            amount,
            "Controller with allowance should credit balance"
        );
    }

    /// @notice Two controllers cannot cross-credit each other's stray tokens.
    function test_AE1_crossControllerIsolation() public {
        // Fund distributor legitimately for project A via terminal.
        uint256 legitimateAmount = 1000 ether;
        rewardToken.mint(terminal, legitimateAmount);
        vm.startPrank(terminal);
        rewardToken.approve(address(distributor), legitimateAmount);
        distributor.processSplitWith(_buildContext(PROJECT_A, address(rewardToken), legitimateAmount));
        vm.stopPrank();

        // Controller B tries to claim from the distributor's held balance without allowance.
        JBSplitHookContext memory ctxB = _buildContext(PROJECT_B, address(rewardToken), legitimateAmount);
        vm.prank(controllerB);
        vm.expectRevert();
        distributor.processSplitWith(ctxB);

        // Project A's balance is intact.
        assertEq(
            distributor.balanceOf(address(votesToken), IERC20(address(rewardToken))),
            legitimateAmount,
            "Project A balance should be intact"
        );
    }
}

// =========================================================================
// AE-2: Vesting dust in _unlockTokenIds
// =========================================================================

contract AuditFixAE2Test is Test {
    AEDirectory internal directory;
    AERewardToken internal rewardToken;
    AEVotesToken internal votesToken;
    JBTokenDistributor internal distributor;

    address internal alice = makeAddr("alice");
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant ROUND_DURATION = 100;
    uint256 internal constant VESTING_ROUNDS = 4;

    function setUp() public {
        directory = new AEDirectory();
        rewardToken = new AERewardToken();
        votesToken = new AEVotesToken();

        directory.setTerminal(PROJECT_ID, address(this), true);

        distributor = new JBTokenDistributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);

        votesToken.mint(alice, 1000 ether);
        vm.prank(alice);
        votesToken.delegate(alice);
    }

    function _tokenId(address staker) internal pure returns (uint256) {
        return uint256(uint160(staker));
    }

    function _advanceToRound(uint256 round) internal {
        uint256 targetTimestamp = distributor.roundStartTimestamp(round) + 1;
        if (block.timestamp < targetTimestamp) {
            vm.warp(targetTimestamp);
        }
        vm.roll(block.number + 1);
    }

    /// @notice 1 wei of dust should be fully claimable after full vesting, not stranded.
    function test_AE2_dustFullyClaimableAfterVesting() public {
        // Fund with exactly 1 wei.
        rewardToken.mint(address(this), 1);
        rewardToken.approve(address(distributor), 1);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), 1);

        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(alice);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // Partial vesting (round 2 of 4): claimAmount should round to 0.
        _advanceToRound(2);
        vm.prank(alice);
        distributor.collectVestedRewards(address(votesToken), tokenIds, tokens, alice);
        assertEq(rewardToken.balanceOf(alice), 0, "Dust should not transfer during partial vesting");

        // Full vesting: the 1 wei dust is forced out.
        _advanceToRound(1 + VESTING_ROUNDS);
        vm.prank(alice);
        distributor.collectVestedRewards(address(votesToken), tokenIds, tokens, alice);
        assertEq(rewardToken.balanceOf(alice), 1, "1 wei dust should be claimable after full vesting");

        // Nothing left to claim.
        assertEq(
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken))),
            0,
            "Nothing should remain after full claim"
        );
    }

    /// @notice Dust entries should not be marked exhausted when claimAmount is zero.
    function test_AE2_dustEntryNotMarkedExhaustedPrematurely() public {
        // Fund with 3 wei. With MAX_SHARE = 100_000, partial claims will produce dust.
        rewardToken.mint(address(this), 3);
        rewardToken.approve(address(distributor), 3);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), 3);

        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(alice);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // Collect at each partial vesting round.
        for (uint256 r = 2; r <= VESTING_ROUNDS; r++) {
            _advanceToRound(r);
            vm.prank(alice);
            distributor.collectVestedRewards(address(votesToken), tokenIds, tokens, alice);
        }

        // Collect after full vesting.
        _advanceToRound(1 + VESTING_ROUNDS);
        vm.prank(alice);
        distributor.collectVestedRewards(address(votesToken), tokenIds, tokens, alice);

        // All 3 wei should be collected with no dust left behind.
        assertEq(rewardToken.balanceOf(alice), 3, "All dust should be collected");
        assertEq(
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken))),
            0,
            "No remaining claim"
        );
    }

    /// @notice Large amounts should still work correctly with the dust fix.
    function test_AE2_largeAmountStillCorrect() public {
        uint256 amount = 1_000_000 ether;
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), amount);

        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(alice);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // Collect partially at each round.
        for (uint256 r = 2; r <= VESTING_ROUNDS; r++) {
            _advanceToRound(r);
            vm.prank(alice);
            distributor.collectVestedRewards(address(votesToken), tokenIds, tokens, alice);
        }

        // Collect remaining after full vesting.
        _advanceToRound(1 + VESTING_ROUNDS);
        vm.prank(alice);
        distributor.collectVestedRewards(address(votesToken), tokenIds, tokens, alice);

        // Alice should have the full amount (her share is 100% since she's the only staker).
        assertEq(rewardToken.balanceOf(alice), amount, "Full amount should be collected");
    }

    /// @notice collectableFor view should match actual collectable including dust.
    function test_AE2_collectableForMatchesActualWithDust() public {
        // Fund with 7 wei: an amount that creates dust across 4 vesting rounds.
        rewardToken.mint(address(this), 7);
        rewardToken.approve(address(distributor), 7);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), 7);

        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(alice);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // Advance to full vesting.
        _advanceToRound(1 + VESTING_ROUNDS);

        // collectableFor should report the full 7 wei.
        uint256 collectable =
            distributor.collectableFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        assertEq(collectable, 7, "collectableFor should include dust");

        // Collect and verify.
        vm.prank(alice);
        distributor.collectVestedRewards(address(votesToken), tokenIds, tokens, alice);
        assertEq(rewardToken.balanceOf(alice), 7, "Actual collected should match collectable");
    }

    /// @notice claimedFor view should include dust in the remaining amount.
    function test_AE2_claimedForIncludesDust() public {
        rewardToken.mint(address(this), 1);
        rewardToken.approve(address(distributor), 1);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), 1);

        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(alice);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // claimedFor should show 1 wei remaining.
        assertEq(
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken))),
            1,
            "claimedFor should include dust"
        );
    }

    /// @notice Multiple vesting entries with dust should all be properly cleaned up.
    function test_AE2_multipleEntriesDustCleanup() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(alice);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // Create two vesting entries across two rounds, each with small amounts.
        rewardToken.mint(address(this), 3);
        rewardToken.approve(address(distributor), 3);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), 3);

        _advanceToRound(1);
        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // Fund again for a new round.
        rewardToken.mint(address(this), 5);
        rewardToken.approve(address(distributor), 5);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), 5);

        _advanceToRound(2);
        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // Advance past all vesting periods (entry 0 releases at round 5, entry 1 at round 6).
        _advanceToRound(2 + VESTING_ROUNDS);

        vm.prank(alice);
        distributor.collectVestedRewards(address(votesToken), tokenIds, tokens, alice);

        // Both entries' dust should be collected: 3 + 5 = 8 wei total.
        assertEq(rewardToken.balanceOf(alice), 8, "All dust from multiple entries should be collected");
        assertEq(
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken))),
            0,
            "No remaining claim after full collection"
        );
    }
}
