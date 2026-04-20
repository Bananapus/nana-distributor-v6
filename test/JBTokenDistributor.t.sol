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

    // 100 blocks per round, 4 vesting rounds.
    uint256 constant ROUND_DURATION = 100;
    uint256 constant VESTING_ROUNDS = 4;

    function setUp() public {
        directory = new MockDirectory();
        rewardToken = new MockRewardToken();
        votesToken = new MockVotesToken();

        directory.setTerminal(projectId, terminal, true);

        distributor = new JBTokenDistributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);

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

    /// @notice Advance to 1 block after the start of the given round.
    function _advanceToRound(uint256 round) internal {
        uint256 targetBlock = distributor.roundStartBlock(round) + 1;
        if (block.number < targetBlock) {
            vm.roll(targetBlock);
        }
    }

    /// @notice Fund the distributor via the direct `fund` method.
    function _fundDistributor(uint256 amount) internal {
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), amount);
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

        // Advance to round 1 (so round 0's start block is in the past for getPastVotes).
        _advanceToRound(1);

        // Begin vesting for alice and bob.
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = _tokenId(alice);
        tokenIds[1] = _tokenId(bob);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(votesToken), tokenIds, tokens);

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

        distributor.beginVesting(address(votesToken), tokenIds, tokens);

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

        distributor.beginVesting(address(votesToken), tokenIds, tokens);

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

        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        uint256 aliceClaimed =
            distributor.claimedFor(address(votesToken), _tokenId(alice), IERC20(address(rewardToken)));
        uint256 bobClaimed = distributor.claimedFor(address(votesToken), _tokenId(bob), IERC20(address(rewardToken)));

        assertEq(aliceClaimed, 700 ether, "Alice gets 70%");
        assertEq(bobClaimed, 300 ether, "Bob gets 30%");
    }

    function test_processSplitWith_onlyAuthorized() public {
        JBSplit memory split = JBSplit({
            percent: 1_000_000_000,
            projectId: 0,
            beneficiary: payable(address(votesToken)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(distributor))
        });

        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(rewardToken), amount: 100 ether, decimals: 18, projectId: projectId, groupId: 0, split: split
        });

        // Unauthorized caller should revert.
        vm.expectRevert(JBTokenDistributor.JBTokenDistributor_Unauthorized.selector);
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

        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // Attempt to release forfeited rewards — should revert with NoAccess.
        vm.expectRevert(JBDistributor.JBDistributor_NoAccess.selector);
        distributor.releaseForfeitedRewards(address(votesToken), tokenIds, tokens, alice);
    }

    function test_multiRoundVesting() public {
        vm.prank(alice);
        votesToken.delegate(alice);
        vm.prank(bob);
        votesToken.delegate(bob);

        _fundDistributor(1000 ether);
        _advanceToRound(1);

        // Begin vesting in round 1.
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = _tokenId(alice);
        tokenIds[1] = _tokenId(bob);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(votesToken), tokenIds, tokens);

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

        // Fund more for round 2.
        _fundDistributor(500 ether);

        // Advance to round 2 to vest new funds.
        // Already in round 3, we can begin vesting for round 3 (which looks at round 3's start block).
        // But we need to be past round 3's start block. We're at round 3 + 1 block already.

        // Begin vesting round 3's rewards.
        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        // Advance past both vesting periods.
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

        distributor.beginVesting(address(votesToken), tokenIds, tokens);

        _advanceToRound(1 + VESTING_ROUNDS);

        // Bob tries to collect Alice's rewards — should revert.
        vm.prank(bob);
        vm.expectRevert(JBDistributor.JBDistributor_NoAccess.selector);
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

        distributor.beginVesting(address(votesToken), tokenIds, tokens);

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

    //*********************************************************************//
    // ----------------------------- internal ---------------------------- //
    //*********************************************************************//

    function _singleTokenId(address staker) internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(staker);
    }
}
