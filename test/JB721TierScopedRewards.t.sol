// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";

import {JB721Distributor} from "../src/JB721Distributor.sol";
import {JBDistributor} from "../src/JBDistributor.sol";
// forge-lint: disable-next-line(unaliased-plain-import)
import {MockHook, MockStore, MockDirectory, MockToken, MockJBTokens, MockJBController} from "./JB721Distributor.t.sol";

/// @title JB721TierScopedRewards
/// @notice End-to-end tests for tier-scoped reward groups: a funded pot keyed to a tier set is claimable only by
/// holders of those tiers, weighted by each tier's voting units, with the per-tier eligible-units denominator.
contract JB721TierScopedRewards is Test {
    JB721Distributor distributor;
    MockToken rewardToken;
    MockHook hook;
    MockStore store;
    MockDirectory directory;
    MockJBTokens jbTokens;
    MockJBController burnController;

    address alice = makeAddr("alice"); // tier 1, votingUnits 100
    address bob = makeAddr("bob"); // tier 2, votingUnits 200
    address charlie = makeAddr("charlie"); // tier 3, votingUnits 500

    uint256 constant ROUND_DURATION = 100;
    uint256 constant VESTING_ROUNDS = 4;

    uint256 constant TOKEN_1 = 1; // tier 1 -> alice
    uint256 constant TOKEN_2 = 2; // tier 2 -> bob
    uint256 constant TOKEN_3 = 3; // tier 3 -> charlie

    function setUp() public {
        store = new MockStore();
        hook = new MockHook(store);
        directory = new MockDirectory();
        jbTokens = new MockJBTokens();
        burnController = new MockJBController(jbTokens);

        distributor = new JB721Distributor(
            IJBDirectory(address(directory)),
            IJBController(address(burnController)),
            IREVLoans(address(0)),
            IREVOwner(address(0)),
            ROUND_DURATION,
            VESTING_ROUNDS,
            0
        );

        rewardToken = new MockToken();
        jbTokens.setToken(1, IJBToken(address(rewardToken)));

        store.setMaxTierIdOf(3);
        store.setTier(1, _tier(1, 100));
        store.setTier(2, _tier(2, 200));
        store.setTier(3, _tier(3, 500));

        store.setTokenTier(TOKEN_1, 1);
        hook.setOwner(TOKEN_1, alice);
        store.setTokenTier(TOKEN_2, 2);
        hook.setOwner(TOKEN_2, bob);
        store.setTokenTier(TOKEN_3, 3);
        hook.setOwner(TOKEN_3, charlie);

        // Per-tier eligible voting units (the tier-scoped denominator source).
        hook.checkpoints().setTierVotingUnits(1, 100);
        hook.checkpoints().setTierVotingUnits(2, 200);
        hook.checkpoints().setTierVotingUnits(3, 500);
    }

    // =====================================================================
    // Exclusive eligibility: only the funded tiers can claim, pro-rata by units.
    // =====================================================================
    function test_tierScopedExclusive_onlyFundedTiersClaimProRata() public {
        // Fund a {tier1, tier2} pot of 300. Denominator = 100 + 200 = 300.
        _fundTier(_tiers(1, 2), 300);

        _advanceToNextRound();

        IERC20[] memory tokens = _rewardTokens();
        uint256[] memory set = _tiers(1, 2);

        // Each holder begins vesting from the {1,2} group.
        _beginVesting(alice, set, TOKEN_1, tokens);
        _beginVesting(bob, set, TOKEN_2, tokens);
        _beginVesting(charlie, set, TOKEN_3, tokens);

        // Pro-rata: alice 100/300 of 300 = 100, bob 200/300 of 300 = 200, charlie (tier 3) excluded = 0.
        assertEq(distributor.claimedFor(address(hook), set, TOKEN_1, IERC20(address(rewardToken))), 100, "alice");
        assertEq(distributor.claimedFor(address(hook), set, TOKEN_2, IERC20(address(rewardToken))), 200, "bob");
        assertEq(distributor.claimedFor(address(hook), set, TOKEN_3, IERC20(address(rewardToken))), 0, "charlie");
    }

    // =====================================================================
    // The funded tier set is recorded and queryable.
    // =====================================================================
    function test_tierIdsOf_recordsSetOnFirstFund() public {
        uint256[] memory set = _tiers(1, 2);
        _fundTier(set, 300);

        uint256 groupId = uint256(keccak256(abi.encode(set)));
        uint256[] memory recorded = distributor.tierIdsOf(address(hook), groupId);
        assertEq(recorded.length, 2, "len");
        assertEq(recorded[0], 1, "t1");
        assertEq(recorded[1], 2, "t2");

        // The legacy group records no tier set.
        assertEq(distributor.tierIdsOf(address(hook), 0).length, 0, "legacy empty");
    }

    // =====================================================================
    // Overlapping groups for the same token vest independently.
    // =====================================================================
    function test_overlappingGroups_claimIndependently() public {
        // Fund {1} (denominator 100) and {1,2} (denominator 300) in the same round.
        _fundTier(_tiers1(1), 100);
        _fundTier(_tiers(1, 2), 300);

        _advanceToNextRound();

        IERC20[] memory tokens = _rewardTokens();

        // Tier-1 token claims its full share from {1} (100/100 * 100 = 100)...
        _beginVesting(alice, _tiers1(1), TOKEN_1, tokens);
        assertEq(
            distributor.claimedFor(address(hook), _tiers1(1), TOKEN_1, IERC20(address(rewardToken))), 100, "group {1}"
        );

        // ...and independently its share from {1,2} (100/300 * 300 = 100). Distinct cursors, no interference.
        _beginVesting(alice, _tiers(1, 2), TOKEN_1, tokens);
        assertEq(
            distributor.claimedFor(address(hook), _tiers(1, 2), TOKEN_1, IERC20(address(rewardToken))),
            100,
            "group {1,2}"
        );
    }

    // =====================================================================
    // A token not owned at the snapshot block is ineligible for that pot.
    // =====================================================================
    function test_postSnapshotMint_getsZero() public {
        _fundTier(_tiers1(1), 100);

        // Token 1 was minted after the round's snapshot block, so `ownerOfAt(snapshot)` returns zero (ineligible).
        uint256 snapshotBlock = distributor.roundSnapshotBlock(distributor.currentRound());
        store.setMintBlock(address(hook), TOKEN_1, snapshotBlock + 1);

        _advanceToNextRound();
        _beginVesting(alice, _tiers1(1), TOKEN_1, _rewardTokens());

        assertEq(
            distributor.claimedFor(address(hook), _tiers1(1), TOKEN_1, IERC20(address(rewardToken))),
            0,
            "not at snapshot"
        );
    }

    // =====================================================================
    // Non-increasing tier sets are rejected (so the group id is canonical).
    // =====================================================================
    function test_nonIncreasingTierIds_reverts() public {
        uint256[] memory bad = new uint256[](2);
        bad[0] = 2;
        bad[1] = 1; // not strictly increasing

        rewardToken.mint(address(this), 100);
        rewardToken.approve(address(distributor), 100);
        vm.expectRevert(
            abi.encodeWithSelector(JBDistributor.JBDistributor_TierIdsNotIncreasing.selector, uint256(2), uint256(1))
        );
        distributor.fund(address(hook), bad, IERC20(address(rewardToken)), 100);
    }

    // =====================================================================
    // Full collection: vested tokens transfer out to the beneficiary.
    // =====================================================================
    function test_tierScoped_fullCollectionTransfers() public {
        _fundTier(_tiers(1, 2), 300);
        _advanceToNextRound();

        IERC20[] memory tokens = _rewardTokens();
        uint256[] memory set = _tiers(1, 2);

        // Begin vesting (release round = claim round + VESTING_ROUNDS), then advance past full vest and collect.
        _beginVesting(alice, set, TOKEN_1, tokens);
        _advanceToRound(distributor.currentRound() + VESTING_ROUNDS);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), set, _single(TOKEN_1), tokens, alice);

        assertEq(rewardToken.balanceOf(alice), 100, "alice collected full tier-1 share");
    }

    // =====================================================================
    // Helpers
    // =====================================================================
    function _tier(uint32 id, uint104 votingUnits) internal pure returns (JB721Tier memory tier) {
        JB721TierFlags memory flags;
        tier = JB721Tier({
            id: id,
            price: 1 ether,
            remainingSupply: 9,
            initialSupply: 10,
            votingUnits: votingUnits,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIpfsUri: bytes32(0),
            category: 0,
            discountPercent: 0,
            flags: flags,
            splitPercent: 0,
            resolvedUri: ""
        });
    }

    function _fundTier(uint256[] memory tierIds, uint256 amount) internal {
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);
        distributor.fund(address(hook), tierIds, IERC20(address(rewardToken)), amount);
    }

    function _beginVesting(address owner, uint256[] memory tierIds, uint256 tokenId, IERC20[] memory tokens) internal {
        vm.prank(owner);
        distributor.beginVesting(address(hook), tierIds, _single(tokenId), tokens);
    }

    function _advanceToRound(uint256 round) internal {
        uint256 target = distributor.roundStartTimestamp(round) + 1;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < target) vm.warp(target);
        vm.roll(block.number + 1);
    }

    function _advanceToNextRound() internal {
        _advanceToRound(distributor.currentRound() + 1);
    }

    function _single(uint256 tokenId) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = tokenId;
    }

    function _tiers1(uint256 t1) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = t1;
    }

    function _tiers(uint256 t1, uint256 t2) internal pure returns (uint256[] memory a) {
        a = new uint256[](2);
        a[0] = t1;
        a[1] = t2;
    }

    function _rewardTokens() internal view returns (IERC20[] memory a) {
        a = new IERC20[](1);
        a[0] = IERC20(address(rewardToken));
    }
}
