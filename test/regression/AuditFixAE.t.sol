// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";

import {JBTokenDistributor} from "../../src/JBTokenDistributor.sol";

// =========================================================================
// Mock contracts
// =========================================================================

contract AEDirectory {
    mapping(uint256 projectId => mapping(address terminal => bool)) public terminals;

    function setTerminal(uint256 projectId, address terminal, bool isTerminal) external {
        terminals[projectId][terminal] = isTerminal;
    }

    function isTerminalOf(uint256 projectId, IJBTerminal terminal) external view returns (bool) {
        return terminals[projectId][address(terminal)];
    }

    // forge-lint: disable-next-line(unused-argument)
    function controllerOf(uint256) external pure returns (address) {
        return address(0);
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
