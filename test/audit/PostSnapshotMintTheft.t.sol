// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JB721Distributor} from "../../src/JB721Distributor.sol";
import {JBDistributor} from "../../src/JBDistributor.sol";

// --- Mocks ---------------------------------------------------------------

contract PSMockDirectory {
    mapping(uint256 => mapping(address => bool)) public terminals;

    function setTerminal(uint256 projectId, address terminal, bool isTerminal) external {
        terminals[projectId][terminal] = isTerminal;
    }

    function isTerminalOf(uint256 projectId, IJBTerminal terminal) external view returns (bool) {
        return terminals[projectId][address(terminal)];
    }

    function controllerOf(uint256) external pure returns (IERC165) {
        return IERC165(address(0));
    }
}

contract PSMockToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PSMockStore {
    uint256 public maxTier;
    mapping(uint256 => JB721Tier) public tiers;
    mapping(uint256 => uint256) public burned;
    mapping(uint256 => uint256) public tokenTiers;
    mapping(address => mapping(uint256 => uint256)) public mintBlockOf;

    function setMaxTierIdOf(uint256 v) external {
        maxTier = v;
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

    function setMintBlock(address hook, uint256 tokenId, uint256 blockNum) external {
        mintBlockOf[hook][tokenId] = blockNum;
    }
}

contract PSMockCheckpoints {
    PSMockStore public store;
    address public hookAddr;

    /// @dev If non-zero, getPastTotalSupply returns this value instead of computing from store.
    uint256 public totalSupplyOverride;

    mapping(address => uint256) public votesOverride;
    mapping(address => bool) public votesOverrideSet;

    constructor(PSMockStore _store, address _hook) {
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
        uint256 max = store.maxTier();
        for (uint256 i = 1; i <= max; i++) {
            JB721Tier memory tier = store.tierOf(hookAddr, i, false);
            if (tier.id == 0 || tier.initialSupply == 0) continue;
            uint256 b = store.burned(i);
            uint256 held = tier.initialSupply - tier.remainingSupply - b;
            total += held * tier.votingUnits;
        }
    }

    function getPastVotes(address account, uint256) external view returns (uint256) {
        if (votesOverrideSet[account]) return votesOverride[account];
        return type(uint256).max;
    }
}

contract PSMockHook {
    PSMockStore public immutable _store;
    PSMockCheckpoints public _checkpoints;
    mapping(uint256 => address) public owners;

    constructor(PSMockStore s) {
        _store = s;
        _checkpoints = new PSMockCheckpoints(s, address(this));
    }

    // solhint-disable-next-line func-name-mixedcase
    function STORE() external view returns (PSMockStore) {
        return _store;
    }

    // solhint-disable-next-line func-name-mixedcase
    function CHECKPOINTS() external view returns (PSMockCheckpoints) {
        return _checkpoints;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = owners[tokenId];
        require(o != address(0), "ERC721: invalid token ID");
        return o;
    }

    function setOwner(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
    }
}

// --- Tests ---------------------------------------------------------------

/// @title PostSnapshotMintTheft
/// @notice Proves the post-snapshot NFT mint reward theft vulnerability and its fix.
///
/// Setup: Tier 1 has votingUnits=100, initialSupply=10, remainingSupply=8 (2 minted).
///   - Token 1 -> alice, Token 2 -> bob. Total snapshot stake = 200.
///
/// Attack: Alice mints token 3 AFTER the snapshot. Without the mintBlockOf check,
///   Alice can vest token 3 and steal 50% of rewards using her historical voting power.
///   With the fix, token 3 is silently skipped since its mintBlock > snapshotBlock.
contract PostSnapshotMintTheftTest is Test {
    JB721Distributor distributor;
    PSMockToken rewardToken;
    PSMockHook hook;
    PSMockStore store;
    PSMockDirectory directory;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant ROUND_DURATION = 100;
    uint256 constant VESTING_ROUNDS = 4;

    function setUp() public {
        store = new PSMockStore();
        hook = new PSMockHook(store);
        directory = new PSMockDirectory();
        distributor = new JB721Distributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);

        directory.setTerminal(1, address(this), true);
        rewardToken = new PSMockToken();

        JB721TierFlags memory flags;
        store.setMaxTierIdOf(1);

        // Tier 1: 2 minted (initialSupply=10, remainingSupply=8), votingUnits=100.
        // Total snapshot stake = 2 * 100 = 200.
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

        // Token 1 -> alice, Token 2 -> bob (both pre-snapshot).
        store.setTokenTier(1, 1);
        hook.setOwner(1, alice);
        store.setTokenTier(2, 1);
        hook.setOwner(2, bob);

        // Fix the total supply at 200 (the snapshot-time value) so it does not change
        // when we modify the tier's remainingSupply in individual tests.
        hook._checkpoints().setTotalSupplyOverride(200);
    }

    function _advanceToRound(uint256 round) internal {
        uint256 target = distributor.roundStartTimestamp(round) + 1;
        if (block.timestamp < target) vm.warp(target);
        vm.roll(block.number + 1);
    }

    function _fundHook(uint256 amount) internal {
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);
        distributor.fund(address(hook), IERC20(address(rewardToken)), amount);
    }

    /// @notice Demonstrates the bug: when mintBlockOf is not tracked (returns 0),
    /// a post-snapshot minted NFT can steal rewards using the owner's historical voting power
    /// from a different, pre-snapshot NFT.
    function test_bug_postSnapshotMint_stealsRewards_whenMintBlockNotTracked() public {
        _fundHook(1000 ether);
        _advanceToRound(1);

        // Lock the snapshot.
        distributor.poke();

        // AFTER the snapshot: Alice mints tokenId 3, but we do NOT set mintBlockOf
        // (simulates pre-fix behavior where mint blocks were not tracked).
        vm.roll(block.number + 5);
        store.setTokenTier(3, 1);
        hook.setOwner(3, alice);
        // mintBlockOf NOT set -> returns 0 -> backward-compatible path -> allows vesting.

        // Alice vests ONLY token 3 (the post-snapshot mint).
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 3;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // The post-snapshot token successfully vested and stole rewards.
        // Token 3 stake = min(100, maxUint) = 100. Reward = 1000 * 100 / 200 = 500.
        uint256 claimed = distributor.claimedFor(address(hook), 3, IERC20(address(rewardToken)));
        assertEq(claimed, 500 ether, "BUG: post-snapshot token stole 50% when mintBlock not tracked");
    }

    /// @notice Proves the fix: when mintBlockOf is set to a block after the snapshot,
    /// the post-snapshot minted NFT is silently skipped and gets zero rewards.
    function test_fix_postSnapshotMint_rejected_whenMintBlockTracked() public {
        _fundHook(1000 ether);
        _advanceToRound(1);
        distributor.poke();

        // AFTER the snapshot: Alice mints tokenId 3.
        uint256 mintBlock = block.number + 5;
        vm.roll(mintBlock);
        store.setTokenTier(3, 1);
        hook.setOwner(3, alice);
        store.setMintBlock(address(hook), 3, mintBlock);

        // Alice tries to vest token 3.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 3;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Token 3 should get ZERO rewards.
        uint256 claimed = distributor.claimedFor(address(hook), 3, IERC20(address(rewardToken)));
        assertEq(claimed, 0, "FIX: post-snapshot token should get zero rewards");
        assertEq(
            distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))),
            0,
            "No rewards should be vesting for post-snapshot token"
        );
    }

    /// @notice Pre-snapshot tokens still vest correctly with mintBlockOf tracking.
    function test_fix_preSnapshotMint_stillVestsCorrectly() public {
        // Set mint blocks for pre-existing tokens (before snapshot).
        uint256 preMintBlock = block.number;
        store.setMintBlock(address(hook), 1, preMintBlock);
        store.setMintBlock(address(hook), 2, preMintBlock);

        _fundHook(1000 ether);
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 aliceClaimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));
        uint256 bobClaimed = distributor.claimedFor(address(hook), 2, IERC20(address(rewardToken)));

        assertEq(aliceClaimed, 500 ether, "Pre-snapshot token 1 should get 50%");
        assertEq(bobClaimed, 500 ether, "Pre-snapshot token 2 should get 50%");
    }

    /// @notice In a mixed batch, the post-snapshot token is skipped while the pre-snapshot token vests.
    function test_fix_mixedBatch_postSnapshotTokenSkipped() public {
        uint256 preMintBlock = block.number;
        store.setMintBlock(address(hook), 1, preMintBlock);
        store.setMintBlock(address(hook), 2, preMintBlock);

        _fundHook(1000 ether);
        _advanceToRound(1);
        distributor.poke();

        // AFTER snapshot: Alice mints token 3.
        uint256 mintBlock = block.number + 5;
        vm.roll(mintBlock);
        store.setTokenTier(3, 1);
        hook.setOwner(3, alice);
        store.setMintBlock(address(hook), 3, mintBlock);

        // Vest token 1 (pre-snapshot, alice) and token 3 (post-snapshot, alice) in one batch.
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 3;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Token 1 (pre-snapshot) should vest: 1000 * 100 / 200 = 500.
        uint256 token1Claimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));
        assertEq(token1Claimed, 500 ether, "Pre-snapshot token should get 50%");

        // Token 3 (post-snapshot) should get ZERO.
        uint256 token3Claimed = distributor.claimedFor(address(hook), 3, IERC20(address(rewardToken)));
        assertEq(token3Claimed, 0, "Post-snapshot token should get zero");
    }

    /// @notice Token minted at exactly the snapshot block is eligible.
    function test_fix_tokenMintedAtSnapshotBlock_isEligible() public {
        _fundHook(1000 ether);
        _advanceToRound(1);
        distributor.poke();
        uint256 snapshotBlock = distributor.roundSnapshotBlock(distributor.currentRound());

        // Set mint blocks to exactly the snapshot block.
        store.setMintBlock(address(hook), 1, snapshotBlock);
        store.setMintBlock(address(hook), 2, snapshotBlock);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 aliceClaimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));
        uint256 bobClaimed = distributor.claimedFor(address(hook), 2, IERC20(address(rewardToken)));

        assertEq(aliceClaimed, 500 ether, "Token at snapshot block should be eligible");
        assertEq(bobClaimed, 500 ether, "Token at snapshot block should be eligible");
    }

    /// @notice Post-snapshot token cannot steal rewards even when the attacker has
    /// legitimate voting power from other tokens.
    function test_fix_attackerWithLegitVotingPower_cannotStealViaNewToken() public {
        // Alice has legit voting power of 100 from token 1.
        hook._checkpoints().setVotesOverride(alice, 100);

        uint256 preMintBlock = block.number;
        store.setMintBlock(address(hook), 1, preMintBlock);
        store.setMintBlock(address(hook), 2, preMintBlock);

        _fundHook(1000 ether);
        _advanceToRound(1);
        distributor.poke();

        // After snapshot: Alice mints token 3.
        uint256 mintBlock = block.number + 5;
        vm.roll(mintBlock);
        store.setTokenTier(3, 1);
        hook.setOwner(3, alice);
        store.setMintBlock(address(hook), 3, mintBlock);

        // Alice tries to vest only token 3 (post-snapshot).
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 3;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Token 3 should get ZERO despite Alice having legitimate pastVotes.
        uint256 token3Claimed = distributor.claimedFor(address(hook), 3, IERC20(address(rewardToken)));
        assertEq(token3Claimed, 0, "Post-snapshot token should get zero even with legit pastVotes");
    }
}
