// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";
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

    function tierIdOfToken(uint256 tokenId) external view returns (uint256 tierId) {
        tierId = tokenTiers[tokenId];
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
    mapping(address account => mapping(uint256 tierId => uint256)) public accountTierActiveVotesOverride;
    mapping(address account => mapping(uint256 tierId => bool)) public accountTierActiveVotesOverrideSet;

    constructor(VPCapMockStore _store, address _hook) {
        store = _store;
        hookAddr = _hook;
    }

    function setAccountTierActiveVotesOverride(address account, uint256 tierId, uint256 value) external {
        accountTierActiveVotesOverride[account][tierId] = value;
        accountTierActiveVotesOverrideSet[account][tierId] = true;
    }

    function setTotalSupplyOverride(uint256 value) external {
        totalSupplyOverride = value;
    }

    function setVotesOverride(address account, uint256 value) external {
        votesOverride[account] = value;
        votesOverrideSet[account] = true;
    }

    function getPastTotalActiveVotes(uint256 blockNumber) external view returns (uint256 activeVotes) {
        blockNumber;
        activeVotes = _totalActiveVotes();
    }

    function getPastTotalSupply(uint256 blockNumber) external view returns (uint256 totalSupply) {
        blockNumber;
        totalSupply = _totalActiveVotes();
    }

    function getPastVotes(address account, uint256) external view returns (uint256) {
        if (votesOverrideSet[account]) return votesOverride[account];
        return 0; // Default: no historical votes (realistic behavior).
    }

    function getPastTotalTierActiveVotes(
        uint256 tierId,
        uint256 blockNumber
    )
        external
        view
        returns (uint256 activeVotes)
    {
        blockNumber;
        activeVotes = _tierActiveVotes(tierId);
    }

    function getPastAccountTierActiveVotes(
        address account,
        uint256 tierId,
        uint256 blockNumber
    )
        external
        view
        returns (uint256 activeVotes)
    {
        if (accountTierActiveVotesOverrideSet[account][tierId]) {
            return accountTierActiveVotesOverride[account][tierId];
        }

        VPCapMockHook hook = VPCapMockHook(hookAddr);
        uint256 tokenCount = hook.tokenIdCount();

        for (uint256 i; i < tokenCount;) {
            uint256 tokenId = hook.tokenIdAt(i);

            if (store.tokenTiers(tokenId) == tierId && hook.ownerOfAt(tokenId, blockNumber) == account) {
                JB721Tier memory tier = store.tierOf(hookAddr, tierId, false);
                activeVotes += tier.votingUnits;
            }

            unchecked {
                ++i;
            }
        }
    }

    function ownerOfAt(uint256 tokenId, uint256 blockNumber) external view returns (address) {
        return VPCapMockHook(hookAddr).ownerOfAt(tokenId, blockNumber);
    }

    function _tierActiveVotes(uint256 tierId) internal view returns (uint256 activeVotes) {
        JB721Tier memory tier = store.tierOf(hookAddr, tierId, false);
        if (tier.id == 0 || tier.initialSupply == 0) return 0;

        uint256 burnedCount = store.burned(tierId);
        uint256 held = tier.initialSupply - tier.remainingSupply - burnedCount;
        activeVotes = held * tier.votingUnits;
    }

    function _totalActiveVotes() internal view returns (uint256 activeVotes) {
        if (totalSupplyOverride != 0) return totalSupplyOverride;
        uint256 max = store.maxTier();
        for (uint256 i = 1; i <= max; i++) {
            activeVotes += _tierActiveVotes(i);
        }
    }
}

contract VPCapMockHook {
    VPCapMockStore public immutable _store;
    VPCapMockCheckpoints public _checkpoints;
    mapping(uint256 => address) public owners;
    mapping(uint256 tokenId => bool tracked) public tokenTracked;
    uint256[] public tokenIds;

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

    function checkpoints() external view returns (VPCapMockCheckpoints) {
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
        _trackTokenId(tokenId);
        owners[tokenId] = owner;
    }

    function tokenIdAt(uint256 index) external view returns (uint256 tokenId) {
        tokenId = tokenIds[index];
    }

    function tokenIdCount() external view returns (uint256 count) {
        count = tokenIds.length;
    }

    function _trackTokenId(uint256 tokenId) internal {
        if (tokenTracked[tokenId]) return;

        tokenTracked[tokenId] = true;
        tokenIds.push(tokenId);
    }
}

// --- Tests ---------------------------------------------------------------

/// @title ActiveTierCapSufficiencyTest
/// @notice Proves that consumed active tier accounting prevents post-snapshot minted NFTs from extracting excess
/// rewards when a hook does not expose mint-block storage.
///
/// Key invariant: an owner's total vested rewards are bounded by their historical active tier units at the snapshot
/// block, regardless of which specific tokens they vest.
contract ActiveTierCapSufficiencyTest is Test {
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
        distributor = new JB721Distributor(
            IJBDirectory(address(directory)),
            IJBController(address(0)),
            IREVLoans(address(0)),
            IREVOwner(address(0)),
            ROUND_DURATION,
            VESTING_ROUNDS,
            0
        );

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
                encodedIpfsUri: bytes32(0),
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

        // Each snapshot holder has 100 active tier units.
        hook._checkpoints().setAccountTierActiveVotesOverride(alice, 1, 100);
        hook._checkpoints().setAccountTierActiveVotesOverride(bob, 1, 100);
        hook._checkpoints().setAccountTierActiveVotesOverride(charlie, 1, 0);

        // Fix active supply at 200 so post-snapshot mints don't inflate the denominator.
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

    /// @notice Post-snapshot mint cannot extract more than the owner's historical active tier units.
    /// Alice has 100 active units at snapshot. She mints token 3 after snapshot and vests both.
    /// Total extraction: 500 ether (capped at 100/200 of pool), NOT 1000 ether.
    function test_activeTierCap_preventsOverExtraction() public {
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

        vm.prank(alice);
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
    function test_activeTierCap_postSnapshotOnlyToken_sameTotal() public {
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

        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 token3Claimed = distributor.claimedFor(address(hook), 3, IERC20(address(rewardToken)));
        assertEq(token3Claimed, 500 ether, "Token 3 vests using Alice's historical 100 active units");

        // Now vest token 1. Alice's budget is already consumed.
        tokenIds[0] = 1;
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 token1Claimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));
        assertEq(token1Claimed, 0, "Token 1 gets 0 (budget spent on token 3)");

        // Total: 500 ether — exactly what Alice is entitled to.
        assertEq(token3Claimed + token1Claimed, 500 ether, "Total extraction bounded by active units");
    }

    /// @notice No historical active tier units means zero rewards, even with a valid NFT.
    function test_activeTierCap_noHistoricalActiveUnits_zeroRewards() public {
        _fundHook(1000 ether);
        _advanceToRound(1);
        distributor.poke();

        // AFTER snapshot: Charlie (0 active tier units at snapshot) mints token 3.
        vm.roll(block.number + 5);
        store.setTokenTier(3, 1);
        hook.setOwner(3, charlie);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 3;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        vm.prank(charlie);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 claimed = distributor.claimedFor(address(hook), 3, IERC20(address(rewardToken)));
        assertEq(claimed, 0, "No historical active units = no rewards");
    }

    /// @notice Multiple post-snapshot tokens are still bounded by historical active tier units.
    /// Alice mints 3 new tokens after snapshot. Total extraction: still 500 ether.
    function test_activeTierCap_multiplePostSnapshotTokens_bounded() public {
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

        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 total;
        for (uint256 i; i < tokenIds.length; i++) {
            total += distributor.claimedFor(address(hook), tokenIds[i], IERC20(address(rewardToken)));
        }

        assertEq(total, 500 ether, "4 tokens but still capped at 100/200 of pool");
    }

    /// @notice Burn-and-remint: Alice burns pre-snapshot token, mints replacement after.
    /// Total extraction: still 500 ether (same as if she kept the original).
    function test_activeTierCap_burnAndRemint_bounded() public {
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

        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 claimed = distributor.claimedFor(address(hook), 3, IERC20(address(rewardToken)));
        assertEq(claimed, 500 ether, "Replacement token capped at Alice's historical 100 active units");
    }

    /// @notice Cross-owner isolation: Alice's post-snapshot mint doesn't affect Bob's rewards.
    function test_activeTierCap_crossOwnerIsolation() public {
        _fundHook(1000 ether);
        _advanceToRound(1);
        distributor.poke();

        // AFTER snapshot: Alice mints token 3.
        vm.roll(block.number + 5);
        store.setTokenTier(3, 1);
        hook.setOwner(3, alice);

        // Each current owner must claim their own NFTs.
        uint256[] memory aliceTokenIds = new uint256[](2);
        aliceTokenIds[0] = 1; // alice
        aliceTokenIds[1] = 3; // alice (post-snapshot)
        uint256[] memory bobTokenIds = new uint256[](1);
        bobTokenIds[0] = 2; // bob
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        vm.prank(alice);
        distributor.beginVesting(address(hook), aliceTokenIds, tokens);
        vm.prank(bob);
        distributor.beginVesting(address(hook), bobTokenIds, tokens);

        uint256 aliceTotal = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)))
            + distributor.claimedFor(address(hook), 3, IERC20(address(rewardToken)));
        uint256 bobTotal = distributor.claimedFor(address(hook), 2, IERC20(address(rewardToken)));

        assertEq(aliceTotal, 500 ether, "Alice gets exactly her 100/200 share");
        assertEq(bobTotal, 500 ether, "Bob gets exactly his 100/200 share");
        assertEq(aliceTotal + bobTotal, 1000 ether, "Full pool distributed, no over-extraction");
    }
}
