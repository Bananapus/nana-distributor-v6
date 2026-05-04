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

contract VPCapMockDirectory {
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

contract VPCapMockToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract VPCapMockStore {
    uint256 public maxTier;
    mapping(uint256 => JB721Tier) public tiers;
    mapping(uint256 => uint256) public burned;
    mapping(uint256 => uint256) public tokenTiers;

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
}

contract VPCapMockCheckpoints {
    VPCapMockStore public store;
    address public hookAddr;

    uint256 public totalSupplyOverride;

    mapping(address => uint256) public votesOverride;
    mapping(address => bool) public votesOverrideSet;

    constructor(VPCapMockStore _store, address _hook) {
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
        return 0; // Default: no historical votes (realistic behavior).
    }

    function ownerOfAt(uint256 tokenId, uint256 blockNumber) external view returns (address) {
        return VPCapMockHook(hookAddr).ownerOfAt(tokenId, blockNumber);
    }
}

contract VPCapMockHook {
    VPCapMockStore public immutable _store;
    VPCapMockCheckpoints public _checkpoints;
    mapping(uint256 => address) public owners;

    constructor(VPCapMockStore s) {
        _store = s;
        _checkpoints = new VPCapMockCheckpoints(s, address(this));
    }

    // solhint-disable-next-line func-name-mixedcase
    function STORE() external view returns (VPCapMockStore) {
        return _store;
    }

    // solhint-disable-next-line func-name-mixedcase
    function CHECKPOINTS() external view returns (VPCapMockCheckpoints) {
        return _checkpoints;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address o = owners[tokenId];
        require(o != address(0), "ERC721: invalid token ID");
        return o;
    }

    function ownerOfAt(uint256 tokenId, uint256) external view returns (address) {
        return owners[tokenId];
    }

    function setOwner(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
    }
}

// --- Tests ---------------------------------------------------------------

/// @title VotingPowerCapSufficiencyTest
/// @notice Proves that the `_consumedVotesOf` tracking against `getPastVotes` is sufficient
/// to prevent post-snapshot minted NFTs from extracting excess rewards — no `mintBlockOf`
/// storage on the 721 hook is needed.
///
/// Key invariant: an owner's total vested rewards are bounded by their historical voting
/// power at the snapshot block, regardless of which specific tokens they vest.
contract VotingPowerCapSufficiencyTest is Test {
    JB721Distributor distributor;
    VPCapMockToken rewardToken;
    VPCapMockHook hook;
    VPCapMockStore store;
    VPCapMockDirectory directory;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    uint256 constant ROUND_DURATION = 100;
    uint256 constant VESTING_ROUNDS = 4;

    function setUp() public {
        store = new VPCapMockStore();
        hook = new VPCapMockHook(store);
        directory = new VPCapMockDirectory();
        distributor = new JB721Distributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);

        directory.setTerminal(1, address(this), true);
        rewardToken = new VPCapMockToken();

        JB721TierFlags memory flags;
        store.setMaxTierIdOf(1);

        // Tier 1: votingUnits=100, 2 minted (initialSupply=10, remainingSupply=8).
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

        // Set realistic historical voting power: each holder had 100 at snapshot.
        hook._checkpoints().setVotesOverride(alice, 100);
        hook._checkpoints().setVotesOverride(bob, 100);
        // Charlie has 0 voting power at snapshot (default).

        // Fix total supply at 200 so post-snapshot mints don't inflate denominator.
        hook._checkpoints().setTotalSupplyOverride(200);
    }

    function _advanceToRound(uint256 round) internal {
        uint256 target = distributor.roundStartTimestamp(round) + 1;
        // Test helper only moves time forward to the requested round boundary.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < target) vm.warp(target);
        vm.roll(block.number + 1);
    }

    function _fundHook(uint256 amount) internal {
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);
        distributor.fund(address(hook), IERC20(address(rewardToken)), amount);
    }

    /// @notice Post-snapshot mint cannot extract more than the owner's historical voting power.
    /// Alice has 100 votes at snapshot. She mints token 3 after snapshot and vests both.
    /// Total extraction: 500 ether (capped at 100/200 of pool), NOT 1000 ether.
    function test_votingPowerCap_preventsOverExtraction() public {
        _fundHook(1000 ether);
        _advanceToRound(1);
        distributor.poke();

        // AFTER snapshot: Alice mints token 3.
        vm.roll(block.number + 5);
        store.setTokenTier(3, 1);
        hook.setOwner(3, alice);

        // Alice vests both tokens 1 (pre-snapshot) and 3 (post-snapshot).
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 3;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Token 1 consumed all 100 votes. Token 3 gets 0 (budget exhausted).
        uint256 token1Claimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));
        uint256 token3Claimed = distributor.claimedFor(address(hook), 3, IERC20(address(rewardToken)));

        assertEq(token1Claimed, 500 ether, "Token 1 gets full share (100/200)");
        assertEq(token3Claimed, 0, "Token 3 gets 0 (voting power budget exhausted)");
    }

    /// @notice Vesting only a post-snapshot token still capped by historical votes.
    /// Alice skips token 1, vests only token 3 (post-snapshot). Gets 500 ether through it.
    /// Then token 1 gets 0 because the budget is spent. Total: still 500.
    function test_votingPowerCap_postSnapshotOnlyToken_sameTotal() public {
        _fundHook(1000 ether);
        _advanceToRound(1);
        distributor.poke();

        // AFTER snapshot: Alice mints token 3.
        vm.roll(block.number + 5);
        store.setTokenTier(3, 1);
        hook.setOwner(3, alice);

        // Alice vests ONLY token 3 (post-snapshot).
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 3;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 token3Claimed = distributor.claimedFor(address(hook), 3, IERC20(address(rewardToken)));
        assertEq(token3Claimed, 500 ether, "Token 3 vests using Alice's historical 100 votes");

        // Now vest token 1. Alice's budget is already consumed.
        tokenIds[0] = 1;
        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 token1Claimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));
        assertEq(token1Claimed, 0, "Token 1 gets 0 (budget spent on token 3)");

        // Total: 500 ether — exactly what Alice is entitled to.
        assertEq(token3Claimed + token1Claimed, 500 ether, "Total extraction bounded by historical votes");
    }

    /// @notice No historical voting power → zero rewards, even with a valid NFT.
    function test_votingPowerCap_noHistoricalVotes_zeroRewards() public {
        _fundHook(1000 ether);
        _advanceToRound(1);
        distributor.poke();

        // AFTER snapshot: Charlie (0 votes at snapshot) mints token 3.
        vm.roll(block.number + 5);
        store.setTokenTier(3, 1);
        hook.setOwner(3, charlie);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 3;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 claimed = distributor.claimedFor(address(hook), 3, IERC20(address(rewardToken)));
        assertEq(claimed, 0, "No historical votes = no rewards");
    }

    /// @notice Multiple post-snapshot tokens still bounded by historical voting power.
    /// Alice mints 3 new tokens after snapshot. Total extraction: still 500 ether.
    function test_votingPowerCap_multiplePostSnapshotTokens_bounded() public {
        _fundHook(1000 ether);
        _advanceToRound(1);
        distributor.poke();

        // AFTER snapshot: Alice mints tokens 3, 4, 5.
        vm.roll(block.number + 5);
        for (uint256 i = 3; i <= 5; i++) {
            store.setTokenTier(i, 1);
            hook.setOwner(i, alice);
        }

        // Alice vests all her tokens (1 pre-snapshot + 3 post-snapshot).
        uint256[] memory tokenIds = new uint256[](4);
        tokenIds[0] = 1;
        tokenIds[1] = 3;
        tokenIds[2] = 4;
        tokenIds[3] = 5;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 total;
        for (uint256 i; i < tokenIds.length; i++) {
            total += distributor.claimedFor(address(hook), tokenIds[i], IERC20(address(rewardToken)));
        }

        assertEq(total, 500 ether, "4 tokens but still capped at 100/200 of pool");
    }

    /// @notice Burn-and-remint: Alice burns pre-snapshot token, mints replacement after.
    /// Total extraction: still 500 ether (same as if she kept the original).
    function test_votingPowerCap_burnAndRemint_bounded() public {
        _fundHook(1000 ether);
        _advanceToRound(1);
        distributor.poke();

        // Simulate burn of token 1 (ownerOf reverts for burned tokens).
        hook.setOwner(1, address(0));

        // AFTER snapshot: Alice mints token 3 as replacement.
        vm.roll(block.number + 5);
        store.setTokenTier(3, 1);
        hook.setOwner(3, alice);

        // Vest token 3 only (token 1 is burned).
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 3;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 claimed = distributor.claimedFor(address(hook), 3, IERC20(address(rewardToken)));
        assertEq(claimed, 500 ether, "Replacement token capped at Alice's historical 100 votes");
    }

    /// @notice Cross-owner isolation: Alice's post-snapshot mint doesn't affect Bob's rewards.
    function test_votingPowerCap_crossOwnerIsolation() public {
        _fundHook(1000 ether);
        _advanceToRound(1);
        distributor.poke();

        // AFTER snapshot: Alice mints token 3.
        vm.roll(block.number + 5);
        store.setTokenTier(3, 1);
        hook.setOwner(3, alice);

        // Vest all three tokens.
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = 1; // alice
        tokenIds[1] = 2; // bob
        tokenIds[2] = 3; // alice (post-snapshot)
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 aliceTotal = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)))
            + distributor.claimedFor(address(hook), 3, IERC20(address(rewardToken)));
        uint256 bobTotal = distributor.claimedFor(address(hook), 2, IERC20(address(rewardToken)));

        assertEq(aliceTotal, 500 ether, "Alice gets exactly her 100/200 share");
        assertEq(bobTotal, 500 ether, "Bob gets exactly his 100/200 share");
        assertEq(aliceTotal + bobTotal, 1000 ether, "Full pool distributed, no over-extraction");
    }
}
