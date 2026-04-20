// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JB721Distributor} from "../src/JB721Distributor.sol";
import {JBDistributor} from "../src/JBDistributor.sol";
import {IJBDistributor} from "../src/interfaces/IJBDistributor.sol";
import {IJB721Distributor} from "../src/interfaces/IJB721Distributor.sol";
import {JBTokenSnapshotData} from "../src/structs/JBTokenSnapshotData.sol";

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

/// @notice Simple ERC20 token for testing.
contract MockToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Second reward token.
contract MockToken2 is ERC20 {
    constructor() ERC20("Reward2", "RWD2") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock 721 tiers hook for testing.
contract MockHook {
    MockStore public immutable _store;

    mapping(uint256 tokenId => address owner) public owners;

    constructor(MockStore store) {
        _store = store;
    }

    function STORE() external view returns (MockStore) {
        return _store;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = owners[tokenId];
        require(owner != address(0), "ERC721: invalid token ID");
        return owner;
    }

    function setOwner(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
    }

    function burn(uint256 tokenId) external {
        delete owners[tokenId];
    }
}

/// @notice Mock 721 tiers hook store for testing.
contract MockStore {
    uint256 public maxTier;
    mapping(uint256 tierId => JB721Tier) public tiers;
    mapping(uint256 tierId => uint256) public burned;
    mapping(uint256 tokenId => uint256 tierId) public tokenTiers;

    function setMaxTierIdOf(uint256 maxTierId) external {
        maxTier = maxTierId;
    }

    function maxTierIdOf(address) external view returns (uint256) {
        return maxTier;
    }

    function setTier(uint256 tierId, JB721Tier memory tier) external {
        tiers[tierId] = tier;
    }

    function tierOf(address, uint256 id, bool) external view returns (JB721Tier memory) {
        return tiers[id];
    }

    function setTokenTier(uint256 tokenId, uint256 tierId) external {
        tokenTiers[tokenId] = tierId;
    }

    function tierOfTokenId(address, uint256 tokenId, bool) external view returns (JB721Tier memory) {
        return tiers[tokenTiers[tokenId]];
    }

    function setBurnedFor(uint256 tierId, uint256 count) external {
        burned[tierId] = count;
    }

    function numberOfBurnedFor(address, uint256 tierId) external view returns (uint256) {
        return burned[tierId];
    }
}

contract JB721DistributorTest is Test {
    JB721Distributor distributor;
    MockToken rewardToken;
    MockToken2 rewardToken2;
    MockHook hook;
    MockStore store;
    MockDirectory directory;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    uint256 constant PROJECT_ID = 1;
    uint256 constant ROUND_DURATION = 100;
    uint256 constant VESTING_ROUNDS = 4;
    uint256 constant MAX_SHARE = 100_000;

    // Default setup:
    // Tier 1: initialSupply=10, remainingSupply=8 -> 2 minted, votingUnits=100
    // Tier 2: initialSupply=5, remainingSupply=4 -> 1 minted, votingUnits=200
    // Total stake = 2*100 + 1*200 = 400
    // Token 1 -> tier 1 -> alice (stake weight 100, share = 25%)
    // Token 2 -> tier 2 -> bob   (stake weight 200, share = 50%)

    function setUp() public {
        store = new MockStore();
        hook = new MockHook(store);
        directory = new MockDirectory();

        distributor = new JB721Distributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);

        // Register this test contract as a terminal for PROJECT_ID so processSplitWith works.
        directory.setTerminal(PROJECT_ID, address(this), true);

        rewardToken = new MockToken();
        rewardToken2 = new MockToken2();

        JB721TierFlags memory flags;

        store.setMaxTierIdOf(2);

        store.setTier(
            1,
            JB721Tier({
                id: 1,
                price: 1 ether,
                remainingSupply: 8,
                initialSupply: 10,
                votingUnits: 100,
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

        store.setTier(
            2,
            JB721Tier({
                id: 2,
                price: 2 ether,
                remainingSupply: 4,
                initialSupply: 5,
                votingUnits: 200,
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

        store.setTokenTier(1, 1);
        hook.setOwner(1, alice);

        store.setTokenTier(2, 2);
        hook.setOwner(2, bob);
    }

    // =====================================================================
    // Constructor
    // =====================================================================

    function test_constructor() public view {
        assertEq(distributor.roundDuration(), ROUND_DURATION);
        assertEq(distributor.vestingRounds(), VESTING_ROUNDS);
        assertEq(distributor.startingBlock(), block.number);
        assertEq(distributor.MAX_SHARE(), MAX_SHARE);
    }

    // =====================================================================
    // View functions
    // =====================================================================

    function test_currentRound() public view {
        assertEq(distributor.currentRound(), 0);
    }

    function test_currentRound_afterRolling() public {
        vm.roll(block.number + ROUND_DURATION);
        assertEq(distributor.currentRound(), 1);

        vm.roll(block.number + ROUND_DURATION * 3);
        assertEq(distributor.currentRound(), 4);
    }

    function test_roundStartBlock() public view {
        assertEq(distributor.roundStartBlock(0), distributor.startingBlock());
        assertEq(distributor.roundStartBlock(1), distributor.startingBlock() + ROUND_DURATION);
        assertEq(distributor.roundStartBlock(5), distributor.startingBlock() + ROUND_DURATION * 5);
    }

    function test_claimedFor_beforeVesting() public view {
        // No vesting started, should be 0.
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 0);
    }

    function test_claimedFor_afterVesting() public {
        _fundHook(1000 ether);
        _beginVestingBoth();

        // Token 1: mulDiv(1000e18, 100, 400) = 250e18.
        // claimedFor = mulDiv(250e18, 100000, 100000) = 250e18.
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 250 ether);
        // Token 2: mulDiv(1000e18, 200, 400) = 500e18.
        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(rewardToken))), 500 ether);
    }

    function test_collectableFor_atStart() public {
        _fundHook(1000 ether);
        _beginVestingBoth();

        // At round 0, releaseRound = 4. lockedShare = (4-0)*100000/4 = 100000.
        // collectableFor = mulDiv(250e18, 100000 - 0 - 100000, 100000) = 0.
        assertEq(distributor.collectableFor(address(hook), 1, IERC20(address(rewardToken))), 0);
    }

    function test_collectableFor_atHalf() public {
        _fundHook(1000 ether);
        _beginVestingBoth();

        vm.roll(block.number + ROUND_DURATION * 2);

        // lockedShare = (4-2)*100000/4 = 50000.
        // collectableFor = mulDiv(250e18, 100000 - 0 - 50000, 100000) = 125e18.
        assertEq(distributor.collectableFor(address(hook), 1, IERC20(address(rewardToken))), 125 ether);
    }

    function test_collectableFor_atFull() public {
        _fundHook(1000 ether);
        _beginVestingBoth();

        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        // lockedShare = 0. collectableFor = 250e18.
        assertEq(distributor.collectableFor(address(hook), 1, IERC20(address(rewardToken))), 250 ether);
        assertEq(distributor.collectableFor(address(hook), 2, IERC20(address(rewardToken))), 500 ether);
    }

    function test_snapshotAtRoundOf() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        JBTokenSnapshotData memory snapshot =
            distributor.snapshotAtRoundOf(address(hook), IERC20(address(rewardToken)), 0);
        assertEq(snapshot.balance, 1000 ether);
        assertEq(snapshot.vestingAmount, 0); // No prior vesting.
    }

    function test_vestingDataOf() public {
        _fundHook(1000 ether);
        _beginVestingBoth();

        (uint256 releaseRound, uint256 amount, uint256 shareClaimed) =
            distributor.vestingDataOf(address(hook), 1, IERC20(address(rewardToken)), 0);
        assertEq(releaseRound, VESTING_ROUNDS); // round 0 + vestingRounds.
        assertEq(amount, 250 ether);
        assertEq(shareClaimed, 0);
    }

    function test_latestVestedIndexOf() public {
        _fundHook(1000 ether);
        _beginVestingBoth();

        assertEq(distributor.latestVestedIndexOf(address(hook), 1, IERC20(address(rewardToken))), 0);

        // Collect fully -> latestVestedIndex should advance.
        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);
        vm.prank(alice);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        assertEq(distributor.latestVestedIndexOf(address(hook), 1, IERC20(address(rewardToken))), 1);
    }

    function test_balanceOf() public {
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 0);

        _fundHook(1000 ether);
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 1000 ether);
    }

    // =====================================================================
    // fund
    // =====================================================================

    function test_fund() public {
        rewardToken.mint(address(this), 500 ether);
        rewardToken.approve(address(distributor), 500 ether);
        distributor.fund(address(hook), IERC20(address(rewardToken)), 500 ether);

        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 500 ether);
        assertEq(rewardToken.balanceOf(address(distributor)), 500 ether);
    }

    /// @notice fund() with native ETH credits hook balance.
    function test_fund_nativeETH() public {
        vm.deal(address(this), 10 ether);

        IERC20 nativeToken = IERC20(address(0x000000000000000000000000000000000000EEEe));
        distributor.fund{value: 10 ether}(address(hook), nativeToken, 0);

        assertEq(distributor.balanceOf(address(hook), nativeToken), 10 ether);
        assertEq(address(distributor).balance, 10 ether);
    }

    /// @notice Native ETH rewards can be vested and collected end-to-end.
    function test_nativeETH_vestAndCollect() public {
        vm.deal(address(this), 100 ether);

        IERC20 nativeToken = IERC20(address(0x000000000000000000000000000000000000EEEe));
        distributor.fund{value: 100 ether}(address(hook), nativeToken, 0);

        // Begin vesting for token 1 (alice, 25% share = 25 ETH).
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = nativeToken;

        distributor.beginVesting(address(hook), tokenIds, tokens);
        assertEq(distributor.claimedFor(address(hook), 1, nativeToken), 25 ether);

        // Advance past full vesting.
        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        // Alice collects.
        uint256 aliceBalBefore = alice.balance;
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);
        assertEq(alice.balance - aliceBalBefore, 25 ether);

        // Distributor's tracked balance decreased.
        assertEq(distributor.balanceOf(address(hook), nativeToken), 75 ether);
    }

    // =====================================================================
    // beginVesting
    // =====================================================================

    function test_beginVesting_exactAmounts() public {
        _fundHook(1000 ether);
        _beginVestingBoth();

        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 750 ether);
    }

    function test_beginVesting_singleToken() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Only token 1 vesting: 250 ether.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 250 ether);
    }

    function test_beginVesting_alreadyVesting_reverts() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        vm.expectRevert(JBDistributor.JBDistributor_AlreadyVesting.selector);
        distributor.beginVesting(address(hook), tokenIds, tokens);
    }

    function test_beginVesting_nextRound_succeeds() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Move to next round, add more funds, should succeed.
        vm.roll(block.number + ROUND_DURATION);
        _fundHook(500 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Two vesting entries for token 1.
        (,, uint256 shareClaimed) = distributor.vestingDataOf(address(hook), 1, IERC20(address(rewardToken)), 1);
        assertEq(shareClaimed, 0);
    }

    function test_beginVesting_snapshotReuse() public {
        _fundHook(1000 ether);

        // First call creates snapshot.
        uint256[] memory tokenIds1 = new uint256[](1);
        tokenIds1[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds1, tokens);

        // Mint more tokens — but snapshot already taken for this round.
        _fundHook(500 ether);

        // Second call in same round with different tokenId should reuse snapshot.
        uint256[] memory tokenIds2 = new uint256[](1);
        tokenIds2[0] = 2;

        distributor.beginVesting(address(hook), tokenIds2, tokens);

        // Both should be based on original 1000 ether snapshot.
        // Token 1: 250e18, Token 2: 500e18. Total = 750e18.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 750 ether);
    }

    function test_beginVesting_emitsClaimedEvent() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        vm.expectEmit(true, true, false, true);
        emit IJBDistributor.Claimed(address(hook), 1, IERC20(address(rewardToken)), 250 ether, VESTING_ROUNDS);

        distributor.beginVesting(address(hook), tokenIds, tokens);
    }

    // =====================================================================
    // collectVestedRewards -- exact value assertions
    // =====================================================================

    function test_collectVestedRewards_fullVesting_exactAmount() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        assertEq(rewardToken.balanceOf(alice), 250 ether);
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 0);
    }

    function test_collectVestedRewards_partialVesting_exactAmounts() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Roll forward 2 of 4 rounds (50%).
        vm.roll(block.number + ROUND_DURATION * 2);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        // lockedShare = (4-2)*100000/4 = 50000. claimAmount = mulDiv(250e18, 50000, 100000) = 125e18.
        assertEq(rewardToken.balanceOf(alice), 125 ether);

        // Roll forward remaining 2 rounds.
        vm.roll(block.number + ROUND_DURATION * 2);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        // After partial: shareClaimed = 50000, lockedShare = 0.
        // claimAmount = mulDiv(250e18, 100000-50000, 100000) = 125e18.
        assertEq(rewardToken.balanceOf(alice), 250 ether);
    }

    function test_collectVestedRewards_quarterVesting() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Roll forward 1 of 4 rounds (25%).
        vm.roll(block.number + ROUND_DURATION);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        // lockedShare = (4-1)*100000/4 = 75000. claimAmount = mulDiv(250e18, 25000, 100000) = 62.5e18.
        assertEq(rewardToken.balanceOf(alice), 62.5 ether);
    }

    function test_collectVestedRewards_threeQuarterVesting() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Roll forward 3 of 4 rounds (75%).
        vm.roll(block.number + ROUND_DURATION * 3);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        // lockedShare = (4-3)*100000/4 = 25000. claimAmount = mulDiv(250e18, 75000, 100000) = 187.5e18.
        assertEq(rewardToken.balanceOf(alice), 187.5 ether);
    }

    function test_collectVestedRewards_noAccess_reverts() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);
        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        vm.prank(bob);
        vm.expectRevert(JBDistributor.JBDistributor_NoAccess.selector);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, bob);
    }

    function test_collectVestedRewards_nothingToCollect() public {
        // No vesting started -- collecting should succeed with zero transfer.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        assertEq(rewardToken.balanceOf(alice), 0);
    }

    function test_collectVestedRewards_emitsCollectedEvent() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);
        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        vm.expectEmit(true, true, false, true);
        emit IJBDistributor.Collected(address(hook), 1, IERC20(address(rewardToken)), 250 ether, VESTING_ROUNDS);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);
    }

    function test_collectVestedRewards_differentBeneficiary() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);
        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        // Alice sends to charlie.
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, charlie);

        assertEq(rewardToken.balanceOf(charlie), 250 ether);
        assertEq(rewardToken.balanceOf(alice), 0);
    }

    // =====================================================================
    // releaseForfeitedRewards
    // =====================================================================

    function test_releaseForfeitedRewards_fullVesting() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 250 ether);

        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);
        hook.burn(1);

        distributor.releaseForfeitedRewards(address(hook), tokenIds, tokens, alice);

        // Vesting amount decremented, tokens NOT sent.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 0);
        assertEq(rewardToken.balanceOf(alice), 0);
    }

    function test_releaseForfeitedRewards_partialVesting() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Roll forward 2 of 4 rounds.
        vm.roll(block.number + ROUND_DURATION * 2);
        hook.burn(1);

        distributor.releaseForfeitedRewards(address(hook), tokenIds, tokens, alice);

        // lockedShare = 50000. claimAmount = mulDiv(250e18, 50000, 100000) = 125e18.
        // totalVestingAmountOf decreased by 125e18.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 125 ether);
        assertEq(rewardToken.balanceOf(alice), 0);
    }

    /// @notice Burned token IDs are skipped during beginVesting — no overbooking.
    function test_burnedTokenSkippedDuringVesting() public {
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        hook.burn(2);
        store.setBurnedFor(2, 1);

        _fundHook(1000 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Only token 1 should vest. Total stake = (2)*100 = 200 (burned excluded).
        // Token 1 stake = 100 → 100/200 = 50% of 1000 = 500 ether.
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 1000 ether);
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 500 ether);

        // Next round should work fine — no underflow.
        vm.roll(block.number + ROUND_DURATION);
        _fundHook(1 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);
    }

    function test_releaseForfeitedRewards_notBurned_reverts() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        vm.expectRevert(JBDistributor.JBDistributor_NoAccess.selector);
        distributor.releaseForfeitedRewards(address(hook), tokenIds, tokens, alice);
    }

    // =====================================================================
    // Burned NFTs excluded from total stake
    // =====================================================================

    function test_burnedNftsExcludedFromTotalStake_exactAmounts() public {
        // Burn 1 NFT from tier 1. Held: tier1 = 2-1=1, tier2 = 1. Total = 1*100 + 1*200 = 300.
        store.setBurnedFor(1, 1);

        _fundHook(900 ether);
        _beginVestingBoth();

        // Token 1: mulDiv(900e18, 100, 300) = 300e18.
        // Token 2: mulDiv(900e18, 200, 300) = 600e18.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 900 ether);
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 300 ether);
        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(rewardToken))), 600 ether);
    }

    // =====================================================================
    // Multiple reward tokens
    // =====================================================================

    function test_multipleRewardTokens() public {
        _fundHook(1000 ether);
        // Fund with second token too.
        rewardToken2.mint(address(this), 500 ether);
        rewardToken2.approve(address(distributor), 500 ether);
        distributor.fund(address(hook), IERC20(address(rewardToken2)), 500 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = IERC20(address(rewardToken));
        tokens[1] = IERC20(address(rewardToken2));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Token 1 share = 100/400 = 25%.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 250 ether);
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken2))), 125 ether);

        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        assertEq(rewardToken.balanceOf(alice), 250 ether);
        assertEq(rewardToken2.balanceOf(alice), 125 ether);
    }

    // =====================================================================
    // Multiple rounds
    // =====================================================================

    function test_multipleRounds_exactAmounts() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // Round 0: fund 1000 and vest.
        _fundHook(1000 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Token 1 gets 250e18 from round 0.

        // Move to round 1: fund 400 more and vest.
        vm.roll(block.number + ROUND_DURATION);
        _fundHook(400 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Snapshot at round 1: balance = 1400 ether (1000 funded + 400 new), vestingAmount = 250e18.
        // distributable = 1400e18 - 250e18 = 1150e18.
        // Token 1 gets mulDiv(1150e18, 100, 400) = 287.5e18 from round 1.

        // Move past all vesting.
        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        assertEq(rewardToken.balanceOf(alice), 250 ether + 287.5 ether);
    }

    // =====================================================================
    // Snapshot edge cases
    // =====================================================================

    function test_snapshotCreatedOnlyOnce() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds1 = new uint256[](1);
        tokenIds1[0] = 1;
        uint256[] memory tokenIds2 = new uint256[](1);
        tokenIds2[0] = 2;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // First vesting creates snapshot.
        distributor.beginVesting(address(hook), tokenIds1, tokens);

        // Add more funds.
        _fundHook(500 ether);

        // Second vesting in same round reuses snapshot.
        distributor.beginVesting(address(hook), tokenIds2, tokens);

        // Both should be based on original 1000 ether snapshot.
        // Token 1: 250e18, Token 2: 500e18. Total = 750e18.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 750 ether);

        JBTokenSnapshotData memory snapshot =
            distributor.snapshotAtRoundOf(address(hook), IERC20(address(rewardToken)), 0);
        assertEq(snapshot.balance, 1000 ether);
    }

    // =====================================================================
    // Conservation invariant
    // =====================================================================

    function test_invariant_totalVestingNeverExceedsBalance() public {
        _fundHook(1000 ether);
        _beginVestingBoth();

        // Vesting (750) <= balance (1000).
        assertLe(
            distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))),
            distributor.balanceOf(address(hook), IERC20(address(rewardToken)))
        );

        // After partial collect, still holds.
        vm.roll(block.number + ROUND_DURATION * 2);
        vm.prank(alice);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        assertLe(
            distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))),
            distributor.balanceOf(address(hook), IERC20(address(rewardToken)))
        );
    }

    function test_invariant_fullCollectDrainsExactAmount() public {
        _fundHook(1000 ether);
        _beginVestingBoth();

        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        // Collect both.
        uint256[] memory aliceIds = new uint256[](1);
        aliceIds[0] = 1;
        uint256[] memory bobIds = new uint256[](1);
        bobIds[0] = 2;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), aliceIds, tokens, alice);
        vm.prank(bob);
        distributor.collectVestedRewards(address(hook), bobIds, tokens, bob);

        assertEq(rewardToken.balanceOf(alice), 250 ether);
        assertEq(rewardToken.balanceOf(bob), 500 ether);
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 0);
        // 250 ether remains undistributed (remaining 25% of stake not claimed by any token).
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 250 ether);
    }

    // =====================================================================
    // Fuzz tests
    // =====================================================================

    function testFuzz_beginVesting_proportional(uint128 fundAmount) public {
        vm.assume(fundAmount > 1 ether);
        vm.assume(fundAmount < type(uint128).max);

        _fundHook(fundAmount);
        _beginVestingBoth();

        uint256 totalVesting = distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken)));
        uint256 claimed1 = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));
        uint256 claimed2 = distributor.claimedFor(address(hook), 2, IERC20(address(rewardToken)));

        // Token 1 is 25% of total stake, Token 2 is 50%.
        // Allow 1 wei rounding tolerance per operation.
        assertEq(claimed1 + claimed2, totalVesting);
        assertApproxEqAbs(claimed1 * 2, claimed2, 2);
    }

    function testFuzz_collectVestedRewards_linearVesting(uint128 fundAmount, uint8 roundsForward) public {
        vm.assume(fundAmount > 1 ether);
        vm.assume(fundAmount < type(uint128).max);
        // Cap roundsForward to vestingRounds to avoid going past release.
        uint256 rounds = bound(roundsForward, 1, VESTING_ROUNDS);

        _fundHook(fundAmount);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 totalClaimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));

        vm.roll(block.number + ROUND_DURATION * rounds);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        uint256 received = rewardToken.balanceOf(alice);
        uint256 expectedFraction = totalClaimed * rounds / VESTING_ROUNDS;

        // Allow small rounding tolerance from mulDiv.
        assertApproxEqAbs(received, expectedFraction, 2);
    }

    function testFuzz_collectVestedRewards_fullVesting_exactRecovery(uint128 fundAmount) public {
        vm.assume(fundAmount > 1 ether);
        vm.assume(fundAmount < type(uint128).max);

        _fundHook(fundAmount);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 totalClaimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));

        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        // Full vesting should recover exact claimed amount.
        assertEq(rewardToken.balanceOf(alice), totalClaimed);
    }

    function testFuzz_collectableEqualsCollected(uint128 fundAmount) public {
        vm.assume(fundAmount > 1 ether);
        vm.assume(fundAmount < type(uint128).max);

        _fundHook(fundAmount);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        vm.roll(block.number + ROUND_DURATION * 2);

        // Check collectableFor equals what we actually collect.
        uint256 collectable = distributor.collectableFor(address(hook), 1, IERC20(address(rewardToken)));

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        assertEq(rewardToken.balanceOf(alice), collectable);
    }

    function testFuzz_multiplePartialCollects_sumToFull(uint128 fundAmount) public {
        vm.assume(fundAmount > 4 ether);
        vm.assume(fundAmount < type(uint128).max);

        _fundHook(fundAmount);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 totalClaimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));

        // Collect at each round.
        for (uint256 r = 1; r <= VESTING_ROUNDS; r++) {
            vm.roll(block.number + ROUND_DURATION);
            vm.prank(alice);
            distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);
        }

        // Sum of all partial collects should equal total claimed (within rounding).
        assertApproxEqAbs(rewardToken.balanceOf(alice), totalClaimed, VESTING_ROUNDS);
    }

    // =====================================================================
    // Tier with zero initialSupply (skipped in _totalStake)
    // =====================================================================

    function test_tierWithZeroSupply_skipped() public {
        // Add a tier 3 with zero supply.
        JB721TierFlags memory flags;
        store.setMaxTierIdOf(3);
        store.setTier(
            3,
            JB721Tier({
                id: 3,
                price: 5 ether,
                remainingSupply: 0,
                initialSupply: 0,
                votingUnits: 1000,
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

        // Should not affect total stake (still 400).
        _fundHook(1000 ether);
        _beginVestingBoth();

        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 250 ether);
    }

    // =====================================================================
    // Empty arrays
    // =====================================================================

    function test_beginVesting_emptyTokenIds() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](0);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // Should succeed with no-op for inner loop.
        distributor.beginVesting(address(hook), tokenIds, tokens);
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 0);
    }

    function test_beginVesting_emptyTokens() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](0);

        // Should succeed with no-op for outer loop.
        distributor.beginVesting(address(hook), tokenIds, tokens);
    }

    function test_collectVestedRewards_emptyArrays() public {
        uint256[] memory tokenIds = new uint256[](0);
        IERC20[] memory tokens = new IERC20[](0);

        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);
    }

    // =====================================================================
    // Double-collect is no-op
    // =====================================================================

    function test_doubleCollect_isNoop() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);
        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);
        assertEq(rewardToken.balanceOf(alice), 250 ether);

        // Second collect should give nothing.
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);
        assertEq(rewardToken.balanceOf(alice), 250 ether);

        // latestVestedIndex should have advanced past all entries.
        assertEq(distributor.latestVestedIndexOf(address(hook), 1, IERC20(address(rewardToken))), 1);
    }

    // =====================================================================
    // Ownership transfer mid-vesting
    // =====================================================================

    function test_ownershipTransfer_newOwnerCollects() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);
        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        // Transfer token 1 from alice to charlie.
        hook.setOwner(1, charlie);

        // Alice can no longer collect.
        vm.prank(alice);
        vm.expectRevert(JBDistributor.JBDistributor_NoAccess.selector);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        // Charlie can collect.
        vm.prank(charlie);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, charlie);
        assertEq(rewardToken.balanceOf(charlie), 250 ether);
    }

    // =====================================================================
    // Three stacked vesting entries -- loop behavior
    // =====================================================================

    function test_threeVestingEntries_collectAllAtOnce() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // Round 0: vest
        _fundHook(1000 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Round 1: vest
        vm.roll(block.number + ROUND_DURATION);
        _fundHook(400 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Round 2: vest
        vm.roll(block.number + ROUND_DURATION);
        _fundHook(200 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Roll past all vesting (round 2 + 4 = round 6 releases last entry).
        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        uint256 totalClaimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        // Should collect all three entries.
        assertEq(rewardToken.balanceOf(alice), totalClaimed);
        assertEq(distributor.latestVestedIndexOf(address(hook), 1, IERC20(address(rewardToken))), 3);
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 0);
    }

    function test_threeVestingEntries_partialCollect_skipsLockedEntries() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // Round 0: vest -> releaseRound = 4
        _fundHook(1000 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);
        uint256 claimed0 = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));

        // Round 1: vest -> releaseRound = 5
        vm.roll(block.number + ROUND_DURATION);
        _fundHook(400 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Round 2: vest -> releaseRound = 6
        vm.roll(block.number + ROUND_DURATION);
        _fundHook(200 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Record total claimed before any collection.
        uint256 totalClaimedBefore = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));

        // Collect at round 4: entry[0] fully vested, entry[1] partially, entry[2] more locked.
        vm.roll(block.number + ROUND_DURATION * 2); // now at round 4

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        // Entry[0] fully collected. Due to loop behavior, entry[2] is skipped this round
        // but will be caught in a future collect. No funds are lost.
        uint256 firstCollect = rewardToken.balanceOf(alice);
        assertGt(firstCollect, 0);
        // At minimum, entry[0]'s full amount should be collected.
        assertGe(firstCollect, claimed0);

        // Collect at round 5: entry[1] fully vests, entry[2] partially.
        vm.roll(block.number + ROUND_DURATION);
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        uint256 secondCollect = rewardToken.balanceOf(alice);
        assertGt(secondCollect, firstCollect);

        // Collect at round 6: entry[2] fully vests.
        vm.roll(block.number + ROUND_DURATION);
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        // All entries should have been fully collected across the three collect calls.
        // claimedFor returns 0 now because latestVestedIndex has advanced past all entries.
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 0);
        assertEq(distributor.latestVestedIndexOf(address(hook), 1, IERC20(address(rewardToken))), 3);
        // Total received across all collects should equal what was originally claimed.
        assertEq(rewardToken.balanceOf(alice), totalClaimedBefore);
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 0);
    }

    /// @notice collectVestedRewards now matches collectableFor even with multiple stacked entries.
    function test_collectMatchesPreviewWithStackedEntries() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _fundHook(1000 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        vm.roll(block.number + ROUND_DURATION);
        _fundHook(400 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        vm.roll(block.number + ROUND_DURATION);
        _fundHook(200 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        vm.roll(block.number + ROUND_DURATION * 2); // now at round 4

        uint256 preview = distributor.collectableFor(address(hook), 1, IERC20(address(rewardToken)));

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        uint256 actualCollected = rewardToken.balanceOf(alice);

        // After fix: actual collection matches the preview.
        assertEq(actualCollected, preview);
    }

    // =====================================================================
    // Forfeiture after partial collect
    // =====================================================================

    function test_forfeitAfterPartialCollect() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Partial collect at 50%.
        vm.roll(block.number + ROUND_DURATION * 2);
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);
        assertEq(rewardToken.balanceOf(alice), 125 ether);

        uint256 vestingAfterPartial = distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken)));
        assertEq(vestingAfterPartial, 125 ether); // 250 - 125 = 125 remaining

        // Burn and release remaining forfeited rewards.
        hook.burn(1);

        vm.roll(block.number + ROUND_DURATION * 2);
        distributor.releaseForfeitedRewards(address(hook), tokenIds, tokens, address(0));

        // All vesting should be released.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 0);
        // Alice keeps what she collected, no more sent.
        assertEq(rewardToken.balanceOf(alice), 125 ether);
    }

    // =====================================================================
    // Forfeited tokens return to distributable pool
    // =====================================================================

    function test_forfeitedTokensReturnToPool() public {
        _fundHook(1000 ether);
        _beginVestingBoth();

        // Token 1 vesting = 250, Token 2 vesting = 500. Total vesting = 750.
        // Balance = 1000, distributable = 250.

        // Burn token 1 and forfeit after full vest.
        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);
        hook.burn(1);
        store.setBurnedFor(1, 1);

        uint256[] memory burnedIds = new uint256[](1);
        burnedIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.releaseForfeitedRewards(address(hook), burnedIds, tokens, address(0));

        // After forfeiture: totalVesting = 500, balance should still be 1000 (forfeited returns to pool).
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 500 ether);
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 1000 ether);
        // Distributable = 1000 - 500 = 500 (was 250 before forfeiture).

        // Move to next round. The forfeited 250 is now distributable.
        vm.roll(block.number + ROUND_DURATION);

        // Vest token 2 again (new round).
        uint256[] memory tokenIds2 = new uint256[](1);
        tokenIds2[0] = 2;
        distributor.beginVesting(address(hook), tokenIds2, tokens);

        // Token 2 should get 200/200 = 100% of 500 distributable = 500 ether from the new round.
        // (only 1 tier with holders now: tier 2 with 1 held NFT)
        JBTokenSnapshotData memory snap =
            distributor.snapshotAtRoundOf(address(hook), IERC20(address(rewardToken)), distributor.currentRound());
        assertEq(snap.balance, 1000 ether);
        assertEq(snap.vestingAmount, 500 ether); // Bob's original vesting from round 0.
    }

    // =====================================================================
    // Zero voting units tier
    // =====================================================================

    function test_zeroVotingUnits_getsZeroShare() public {
        // Change tier 1 to have 0 voting units.
        JB721TierFlags memory flags;
        store.setTier(
            1,
            JB721Tier({
                id: 1,
                price: 1 ether,
                remainingSupply: 8,
                initialSupply: 10,
                votingUnits: 0, // zero!
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

        _fundHook(1000 ether);
        _beginVestingBoth();

        // Token 1 has 0 voting units, gets nothing. Total stake = 0 + 200 = 200.
        // Token 1: mulDiv(1000e18, 0, 200) = 0.
        // Token 2: mulDiv(1000e18, 200, 200) = 1000e18.
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 0);
        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(rewardToken))), 1000 ether);
    }

    // =====================================================================
    // Collect multiple tokenIds in one call (same owner)
    // =====================================================================

    function test_collectMultipleTokenIds_sameOwner() public {
        // Give alice both tokens.
        hook.setOwner(2, alice);

        _fundHook(1000 ether);
        _beginVestingBoth();

        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        // Alice gets both shares in one call.
        assertEq(rewardToken.balanceOf(alice), 750 ether);
    }

    // =====================================================================
    // collectableFor == claimedFor after full vest (invariant)
    // =====================================================================

    function test_collectableEqualsClaimedAfterFullVest() public {
        _fundHook(1000 ether);
        _beginVestingBoth();

        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        IERC20 token = IERC20(address(rewardToken));
        assertEq(distributor.collectableFor(address(hook), 1, token), distributor.claimedFor(address(hook), 1, token));
        assertEq(distributor.collectableFor(address(hook), 2, token), distributor.claimedFor(address(hook), 2, token));
    }

    // =====================================================================
    // Snapshot captures vesting amount correctly across rounds
    // =====================================================================

    function test_snapshotWithExistingVesting() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // Round 0: fund and vest.
        _fundHook(1000 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        JBTokenSnapshotData memory snap0 = distributor.snapshotAtRoundOf(address(hook), IERC20(address(rewardToken)), 0);
        assertEq(snap0.balance, 1000 ether);
        assertEq(snap0.vestingAmount, 0); // No prior vesting when round 0 snapshot taken.

        // Round 1: snapshot should reflect vesting from round 0.
        vm.roll(block.number + ROUND_DURATION);
        _fundHook(500 ether);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        JBTokenSnapshotData memory snap1 = distributor.snapshotAtRoundOf(address(hook), IERC20(address(rewardToken)), 1);
        assertEq(snap1.balance, 1500 ether); // 1000 + 500
        assertEq(snap1.vestingAmount, 250 ether); // Token 1's round-0 vesting
    }

    // =====================================================================
    // Reentrancy via malicious ERC20
    // =====================================================================

    function test_reentrancy_maliciousToken() public {
        // Deploy a reentrant token.
        ReentrantToken maliciousToken = new ReentrantToken(address(distributor));

        // Fund the hook with the malicious token.
        maliciousToken.mint(address(this), 1000 ether);
        maliciousToken.approve(address(distributor), 1000 ether);
        distributor.fund(address(hook), IERC20(address(maliciousToken)), 1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(maliciousToken));

        // Vest.
        distributor.beginVesting(address(hook), tokenIds, tokens);

        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        // Set up reentrancy: on transfer, the token calls collectVestedRewards again.
        maliciousToken.setReentrancyTarget(address(hook), tokenIds, tokens, alice);

        // The reentrant call should not yield extra tokens because:
        // After first collect, shareClaimed = MAX_SHARE and latestVestedIndex advances.
        // The reentrant collect call processes the same entry but gets claimAmount = 0.
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        // Alice should only get 250 ether (25% of 1000), not double.
        assertEq(maliciousToken.balanceOf(alice), 250 ether);
    }

    // =====================================================================
    // Fuzz: collect at any round produces correct amount
    // =====================================================================

    function testFuzz_collectableFor_atAnyRound(uint8 roundsForward) public {
        uint256 rounds = bound(roundsForward, 0, VESTING_ROUNDS);

        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        vm.roll(block.number + ROUND_DURATION * rounds);

        uint256 collectable = distributor.collectableFor(address(hook), 1, IERC20(address(rewardToken)));
        uint256 claimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));

        // Collectable should always be <= claimed.
        assertLe(collectable, claimed);

        // At full vesting, collectable == claimed.
        if (rounds == VESTING_ROUNDS) {
            assertEq(collectable, claimed);
        }

        // Collectable should be proportional to rounds passed.
        uint256 expectedCollectable = claimed * rounds / VESTING_ROUNDS;
        assertApproxEqAbs(collectable, expectedCollectable, 1);
    }

    // =====================================================================
    // Fuzz: conservation -- total distributed never exceeds funded
    // =====================================================================

    function testFuzz_conservation(uint128 rawFund1, uint128 rawFund2) public {
        uint256 fund1 = bound(rawFund1, 1 ether, type(uint64).max);
        uint256 fund2 = bound(rawFund2, 1 ether, type(uint64).max);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // Round 0.
        _fundHook(fund1);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Round 1.
        vm.roll(block.number + ROUND_DURATION);
        _fundHook(fund2);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Full vest.
        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);

        uint256[] memory aliceIds = new uint256[](1);
        aliceIds[0] = 1;
        uint256[] memory bobIds = new uint256[](1);
        bobIds[0] = 2;

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), aliceIds, tokens, alice);
        vm.prank(bob);
        distributor.collectVestedRewards(address(hook), bobIds, tokens, bob);

        uint256 totalDistributed = rewardToken.balanceOf(alice) + rewardToken.balanceOf(bob);
        uint256 totalFunded = uint256(fund1) + uint256(fund2);

        // Total distributed should never exceed total funded.
        assertLe(totalDistributed, totalFunded);
        // Distributor should hold the remainder.
        assertEq(rewardToken.balanceOf(address(distributor)), totalFunded - totalDistributed);
    }

    // =====================================================================
    // Multi-hook isolation
    // =====================================================================

    function test_multiHook_fundsIsolated() public {
        // Create a second hook.
        MockStore store2 = new MockStore();
        MockHook hook2 = new MockHook(store2);

        JB721TierFlags memory flags;

        store2.setMaxTierIdOf(1);
        store2.setTier(
            1,
            JB721Tier({
                id: 1,
                price: 1 ether,
                remainingSupply: 9,
                initialSupply: 10,
                votingUnits: 100,
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
        store2.setTokenTier(1, 1);
        hook2.setOwner(1, charlie);

        // Fund hook1 with 1000, hook2 with 500.
        _fundHook(1000 ether);
        rewardToken.mint(address(this), 500 ether);
        rewardToken.approve(address(distributor), 500 ether);
        distributor.fund(address(hook2), IERC20(address(rewardToken)), 500 ether);

        // Balances are isolated.
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 1000 ether);
        assertEq(distributor.balanceOf(address(hook2), IERC20(address(rewardToken))), 500 ether);

        // Vest on hook1.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Vest on hook2.
        distributor.beginVesting(address(hook2), tokenIds, tokens);

        // Vesting amounts are isolated.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 250 ether);
        assertEq(distributor.totalVestingAmountOf(address(hook2), IERC20(address(rewardToken))), 500 ether);

        // Collect from hook2 -- should not affect hook1.
        vm.roll(block.number + ROUND_DURATION * VESTING_ROUNDS);
        vm.prank(charlie);
        distributor.collectVestedRewards(address(hook2), tokenIds, tokens, charlie);

        assertEq(rewardToken.balanceOf(charlie), 500 ether);
        // hook1 balance unchanged (only hook1 vesting amount decremented from its pool).
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 1000 ether);
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 250 ether);
    }

    // =====================================================================
    // Helpers
    // =====================================================================

    function _fundHook(uint256 amount) internal {
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);
        distributor.fund(address(hook), IERC20(address(rewardToken)), amount);
    }

    function _beginVestingBoth() internal {
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));
        distributor.beginVesting(address(hook), tokenIds, tokens);
    }

    // =====================================================================
    // Split Hook
    // =====================================================================

    function _splitContext(address token, uint256 amount) internal view returns (JBSplitHookContext memory) {
        return JBSplitHookContext({
            token: token,
            amount: amount,
            decimals: 18,
            projectId: 1,
            groupId: uint256(uint160(token)),
            split: JBSplit({
                percent: 500_000_000, // 50%
                projectId: 0,
                beneficiary: payable(address(hook)), // hook address as beneficiary
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(distributor))
            })
        });
    }

    /// @notice processSplitWith pulls ERC-20 tokens via transferFrom and credits hook balance.
    function test_processSplitWith_erc20() public {
        uint256 amount = 10 ether;
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);

        distributor.processSplitWith(_splitContext(address(rewardToken), amount));

        assertEq(rewardToken.balanceOf(address(distributor)), amount);
        assertEq(rewardToken.balanceOf(address(this)), 0);
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), amount);
    }

    /// @notice processSplitWith accepts native ETH via msg.value.
    function test_processSplitWith_nativeETH() public {
        uint256 amount = 5 ether;
        vm.deal(address(this), amount);

        uint256 balBefore = address(distributor).balance;

        distributor.processSplitWith{value: amount}(
            _splitContext(address(0x000000000000000000000000000000000000EEEe), amount)
        );

        assertEq(address(distributor).balance, balBefore + amount);
    }

    /// @notice processSplitWith with zero amount is a no-op for ERC-20.
    function test_processSplitWith_zeroAmount() public {
        distributor.processSplitWith(_splitContext(address(rewardToken), 0));
        // No revert, no balance change.
    }

    /// @notice ERC-20 tokens received via processSplitWith are distributable in the next beginVesting.
    function test_processSplitWith_tokensDistributableViaVesting() public {
        uint256 amount = 100 ether;
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);

        // Send tokens via split hook.
        distributor.processSplitWith(_splitContext(address(rewardToken), amount));

        // Verify tokens are in the distributor and credited to hook.
        assertEq(rewardToken.balanceOf(address(distributor)), amount);
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), amount);

        // Now begin vesting -- tokens should be distributed pro-rata.
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Token 1 (tier1, 100 voting units) gets 100/400 = 25% of 100 ether = 25 ether.
        // Token 2 (tier2, 200 voting units) gets 200/400 = 50% of 100 ether = 50 ether.
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 25 ether);
        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(rewardToken))), 50 ether);
    }

    /// @notice supportsInterface returns true for IJBSplitHook, IJB721Distributor, and IERC165.
    function test_supportsInterface() public view {
        assertTrue(distributor.supportsInterface(type(IJBSplitHook).interfaceId));
        assertTrue(distributor.supportsInterface(type(IJB721Distributor).interfaceId));
        assertTrue(distributor.supportsInterface(type(IERC165).interfaceId));
        // Random interface should return false.
        assertFalse(distributor.supportsInterface(0xdeadbeef));
    }

    /// @notice processSplitWith with no allowance credits balance if tokens were already sent (controller pattern).
    function test_processSplitWith_erc20_noAllowance_creditsBalance() public {
        uint256 amount = 10 ether;
        // Send tokens directly to distributor (controller pattern).
        rewardToken.mint(address(distributor), amount);

        // No approval -- simulates controller having already sent tokens directly.
        distributor.processSplitWith(_splitContext(address(rewardToken), amount));
        // Balance credited to hook even though no pull happened.
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), amount);
    }

    /// @notice Controller pattern: tokens sent before processSplitWith, no pull needed.
    function test_processSplitWith_controllerPattern() public {
        // Register this test as controller (not just terminal) for the controller path.
        directory.setTerminal(PROJECT_ID, address(this), false);
        directory.setController(PROJECT_ID, address(this));

        uint256 amount = 50 ether;
        // Controller sends tokens directly to the distributor first.
        rewardToken.mint(address(distributor), amount);

        // Controller calls processSplitWith -- no allowance, tokens already there.
        distributor.processSplitWith(_splitContext(address(rewardToken), amount));

        // Balance credited to hook.
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), amount);

        // Tokens are distributable via vesting.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), amount * 100 / 400);
    }

    /// @notice Fuzz: processSplitWith with random ERC-20 amounts.
    function testFuzz_processSplitWith_erc20(uint128 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, type(uint128).max);
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);

        distributor.processSplitWith(_splitContext(address(rewardToken), amount));

        assertEq(rewardToken.balanceOf(address(distributor)), amount);
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), amount);
    }

    /// @notice processSplitWith routes to correct hook via split.beneficiary.
    function test_processSplitWith_routesViaBeneficiary() public {
        // Create a second hook.
        MockStore store2 = new MockStore();
        MockHook hook2 = new MockHook(store2);

        uint256 amount = 100 ether;
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);

        // Split context with hook2 as beneficiary.
        JBSplitHookContext memory ctx = JBSplitHookContext({
            token: address(rewardToken),
            amount: amount,
            decimals: 18,
            projectId: 1,
            groupId: uint256(uint160(address(rewardToken))),
            split: JBSplit({
                percent: 500_000_000,
                projectId: 0,
                beneficiary: payable(address(hook2)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(distributor))
            })
        });

        distributor.processSplitWith(ctx);

        // Funds credited to hook2, not hook1.
        assertEq(distributor.balanceOf(address(hook2), IERC20(address(rewardToken))), amount);
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 0);
    }

    /// @notice processSplitWith reverts when caller is not a terminal or controller.
    function test_processSplitWith_unauthorized_reverts() public {
        address unauthorized = makeAddr("unauthorized");
        uint256 amount = 10 ether;
        rewardToken.mint(unauthorized, amount);

        vm.startPrank(unauthorized);
        rewardToken.approve(address(distributor), amount);

        vm.expectRevert(JB721Distributor.JB721Distributor_Unauthorized.selector);
        distributor.processSplitWith(_splitContext(address(rewardToken), amount));
        vm.stopPrank();
    }
}

/// @notice ERC20 that reenters collectVestedRewards on transfer.
contract ReentrantToken is ERC20 {
    address public distributor;
    bool public reentrancyArmed;
    address public reentrantHook;
    uint256[] public reentrantTokenIds;
    IERC20[] public reentrantTokens;
    address public reentrantBeneficiary;

    constructor(address _distributor) ERC20("Reentrant", "REENT") {
        distributor = _distributor;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setReentrancyTarget(
        address hook,
        uint256[] memory tokenIds,
        IERC20[] memory tokens,
        address beneficiary
    )
        external
    {
        reentrantHook = hook;
        // Store for reentrancy.
        delete reentrantTokenIds;
        delete reentrantTokens;
        for (uint256 i; i < tokenIds.length; i++) {
            reentrantTokenIds.push(tokenIds[i]);
        }
        for (uint256 i; i < tokens.length; i++) {
            reentrantTokens.push(tokens[i]);
        }
        reentrantBeneficiary = beneficiary;
        reentrancyArmed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        // Perform the actual transfer first.
        bool result = super.transfer(to, amount);

        // Attempt reentrancy once.
        if (reentrancyArmed) {
            reentrancyArmed = false; // Prevent infinite recursion.
            // Try to re-collect. This should be a no-op because state was already updated.
            try JBDistributor(distributor)
                .collectVestedRewards(reentrantHook, reentrantTokenIds, reentrantTokens, reentrantBeneficiary) {}
                catch {}
        }

        return result;
    }
}
