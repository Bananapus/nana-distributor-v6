// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JB721Distributor} from "../../src/JB721Distributor.sol";
import {JBDistributor} from "../../src/JBDistributor.sol";
import {IJBDistributor} from "../../src/interfaces/IJBDistributor.sol";

/// @notice Mock JB directory for H-26 tests.
contract H26MockDirectory {
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

/// @notice Simple ERC20 reward token for H-26 tests.
contract H26MockRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock store that tracks tiers and token-to-tier mappings.
contract H26MockStore {
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

    /// @dev Returns 0 for all tokens (backward-compatible: allows vesting).
    function mintBlockOf(address, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice Mock checkpoints with explicit per-address vote overrides for H-26 testing.
/// @dev getPastTotalSupply computes from the store; getPastVotes uses explicit overrides.
contract H26MockCheckpoints {
    H26MockStore public store;
    address public hookAddr;

    /// @dev Override: if non-zero, getPastTotalSupply returns this instead of computing from store.
    uint256 public totalSupplyOverride;

    /// @dev Per-address vote overrides. If set, getPastVotes returns this value.
    mapping(address => uint256) public votesOverride;

    /// @dev Tracks whether a per-address override was explicitly set (to allow setting 0).
    mapping(address => bool) public votesOverrideSet;

    constructor(H26MockStore _store, address _hook) {
        store = _store;
        hookAddr = _hook;
    }

    function setTotalSupplyOverride(uint256 value) external {
        totalSupplyOverride = value;
    }

    function setVotesOverride(address account, uint256 value) external {
        votesOverride[account] = value;
        votesOverrideSet[account] = true;
    }

    function getPastTotalSupply(uint256) external view returns (uint256 total) {
        if (totalSupplyOverride != 0) return totalSupplyOverride;
        // Dynamically compute from store: sum over tiers of (minted - burned) * votingUnits.
        uint256 maxTierCount = store.maxTier();
        for (uint256 i = 1; i <= maxTierCount; i++) {
            JB721Tier memory tier = store.tierOf(hookAddr, i, false);
            if (tier.id == 0 || tier.initialSupply == 0) continue;
            uint256 burnedCount = store.burned(i);
            uint256 held = tier.initialSupply - tier.remainingSupply - burnedCount;
            total += held * tier.votingUnits;
        }
    }

    function getPastVotes(address account, uint256) external view returns (uint256) {
        if (votesOverrideSet[account]) return votesOverride[account];
        // Default: return max so min(votingUnits, pastVotes) = votingUnits for any holder.
        return type(uint256).max;
    }
}

/// @notice Mock 721 hook for H-26 tests.
contract H26MockHook {
    H26MockStore public immutable _store;
    H26MockCheckpoints public _checkpoints;

    mapping(uint256 tokenId => address owner) public owners;

    constructor(H26MockStore store_) {
        _store = store_;
        _checkpoints = new H26MockCheckpoints(store_, address(this));
    }

    function STORE() external view returns (H26MockStore) {
        return _store;
    }

    function CHECKPOINTS() external view returns (H26MockCheckpoints) {
        return _checkpoints;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = owners[tokenId];
        require(owner != address(0), "ERC721: invalid token ID");
        return owner;
    }

    function ownerOfAt(uint256 tokenId, uint256) external view returns (address) {
        return owners[tokenId];
    }

    function setOwner(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
    }

    function burn(uint256 tokenId) external {
        delete owners[tokenId];
    }
}

/// @notice Tests for H-26: per-owner voting power cap in JB721Distributor.
/// @dev Verifies that an owner holding multiple NFTs cannot claim more rewards than their
/// historical voting power allows. The `_vestTokenIds` override in JB721Distributor
/// tracks consumed voting power per owner and caps each NFT's effective stake.
contract H26VotingPowerCapTest is Test {
    JB721Distributor distributor;
    H26MockRewardToken rewardToken;
    H26MockHook hook;
    H26MockStore store;
    H26MockDirectory directory;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant PROJECT_ID = 1;
    uint256 constant ROUND_DURATION = 100;
    uint256 constant VESTING_ROUNDS = 4;

    function setUp() public {
        store = new H26MockStore();
        hook = new H26MockHook(store);
        directory = new H26MockDirectory();

        distributor = new JB721Distributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);

        // Register this test contract as a terminal for PROJECT_ID so processSplitWith works.
        directory.setTerminal(PROJECT_ID, address(this), true);

        rewardToken = new H26MockRewardToken();

        JB721TierFlags memory flags;

        // Tier 1: votingUnits = 50 each.
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

    function _advanceToRound(uint256 round) internal {
        uint256 targetTimestamp = distributor.roundStartTimestamp(round) + 1;
        if (block.timestamp < targetTimestamp) {
            vm.warp(targetTimestamp);
        }
        vm.roll(block.number + 1);
    }

    function _fundHook(uint256 amount) internal {
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);
        distributor.fund(address(hook), IERC20(address(rewardToken)), amount);
    }

    // =====================================================================
    // H-26 Tests
    // =====================================================================

    /// @notice Owner has 3 NFTs (50 voting units each = 150 total) but only 100 past votes.
    /// Should get rewards for only 100 votes total, not 150.
    function test_h26_multipleNFTsCappedAtVotingPower() public {
        // Alice has 3 NFTs x 50 voting units = 150 votingUnits total.
        // But her pastVotes is only 100 — so she should be capped at 100.
        hook._checkpoints().setVotesOverride(alice, 100);

        // Total supply = 3 minted * 50 voting units = 150.
        // (store has initialSupply=10, remainingSupply=7, so 3 minted)

        _fundHook(1500 ether);

        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        tokenIds[2] = 3;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Without the cap, Alice would get: mulDiv(1500, 50, 150) * 3 = 500 * 3 = 1500 ether.
        // With the cap: Alice has 100 past votes across 3 NFTs (50 each).
        // NFT 1: min(50, 100 remaining) = 50 -> consumed = 50
        // NFT 2: min(50, 50 remaining) = 50 -> consumed = 100
        // NFT 3: min(50, 0 remaining) = 0 -> skipped
        // Total effective stake = 100 out of 150 total supply.
        // Alice total = mulDiv(1500, 50, 150) + mulDiv(1500, 50, 150) = 500 + 500 = 1000 ether.
        uint256 claimed1 = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));
        uint256 claimed2 = distributor.claimedFor(address(hook), 2, IERC20(address(rewardToken)));
        uint256 claimed3 = distributor.claimedFor(address(hook), 3, IERC20(address(rewardToken)));

        uint256 totalClaimed = claimed1 + claimed2 + claimed3;

        // Each NFT gets mulDiv(1500, 50, 150) = 500 ether for 50 effective units,
        // but NFT 3 gets 0 (remaining pastVotes exhausted).
        assertEq(claimed1, 500 ether, "NFT 1: should get full 50-unit share");
        assertEq(claimed2, 500 ether, "NFT 2: should get full 50-unit share");
        assertEq(claimed3, 0, "NFT 3: should get 0 (voting power exhausted)");
        assertEq(totalClaimed, 1000 ether, "Total claimed should be capped at 100/150 of distributable");

        // Verify total vesting reflects the capped amount, not the full 150-unit amount.
        assertEq(
            distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))),
            1000 ether,
            "Total vesting should reflect capped amount"
        );
    }

    /// @notice An owner with 1 NFT and sufficient past votes gets the full reward (backward compatibility).
    function test_h26_singleNFTUnaffected() public {
        // Alice has 3 NFTs but we only vest 1 — pastVotes = 100 which is >= 50 voting units.
        hook._checkpoints().setVotesOverride(alice, 100);

        _fundHook(1500 ether);

        // Only vest token 1.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // With 1 NFT at 50 voting units, pastVotes=100 is more than enough.
        // Alice's NFT 1 stake = min(50, 100) = 50.
        // Share = mulDiv(1500, 50, 150) = 500 ether.
        uint256 claimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));
        assertEq(claimed, 500 ether, "Single NFT should get full reward when pastVotes >= votingUnits");

        // Verify total vesting.
        assertEq(
            distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))),
            500 ether,
            "Total vesting should equal single NFT share"
        );
    }
}
