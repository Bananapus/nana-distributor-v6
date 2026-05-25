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
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JB721Distributor} from "../src/JB721Distributor.sol";
import {JBDistributor} from "../src/JBDistributor.sol";
import {IJBDistributor} from "../src/interfaces/IJBDistributor.sol";
import {IJB721Distributor} from "../src/interfaces/IJB721Distributor.sol";

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

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Second reward token.
contract MockToken2 is ERC20 {
    constructor() ERC20("Reward2", "RWD2") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice Minimal JBTokens registry for burn tests.
contract MockJBTokens {
    mapping(IJBToken token => uint256 projectId) public projectIdOf;
    mapping(uint256 projectId => IJBToken token) public tokenOf;

    function setToken(uint256 projectId, IJBToken token) external {
        projectIdOf[token] = projectId;
        tokenOf[projectId] = token;
    }
}

/// @notice Minimal JBController for distributor burn tests.
contract MockJBController {
    MockJBTokens public immutable tokens;

    constructor(MockJBTokens tokens_) {
        tokens = tokens_;
    }

    function TOKENS() external view returns (MockJBTokens) {
        return tokens;
    }

    function burnTokensOf(address holder, uint256 projectId, uint256 tokenCount, string calldata) external {
        tokens.tokenOf(projectId).burn(holder, tokenCount);
    }
}

/// @notice Mock checkpoints contract that provides IVotes-compatible getPastVotes/getPastTotalSupply.
/// @dev Computes getPastTotalSupply dynamically from the store (tier data minus burned), matching
/// the old _totalStake logic. getPastVotes returns type(uint256).max for any address so that
/// min(votingUnits, pastVotes) always equals votingUnits.
contract MockCheckpoints {
    MockStore public store;
    address public hookAddr;

    /// @dev Override: if non-zero, getPastTotalSupply returns this instead of computing from store.
    uint256 public totalSupplyOverride;

    /// @dev Per-address vote overrides. If set to non-zero, getPastVotes returns this value.
    mapping(address => uint256) public votesOverride;

    /// @dev Tracks whether a per-address override was explicitly set (to allow setting 0).
    mapping(address => bool) public votesOverrideSet;

    constructor(MockStore _store, address _hook) {
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
        uint256 maxTier = store.maxTier();
        for (uint256 i = 1; i <= maxTier; i++) {
            JB721Tier memory tier = store.tierOf(hookAddr, i, false);
            if (tier.id == 0 || tier.initialSupply == 0) continue;
            uint256 burned = store.burned(i);
            uint256 held = tier.initialSupply - tier.remainingSupply - burned;
            total += held * tier.votingUnits;
        }
    }

    function getPastVotes(address account, uint256) external view returns (uint256) {
        if (votesOverrideSet[account]) return votesOverride[account];
        // Default: return max so min(votingUnits, pastVotes) = votingUnits for any holder.
        return type(uint256).max;
    }

    function ownerOfAt(uint256 tokenId, uint256 blockNumber) external view returns (address) {
        return MockHook(hookAddr).ownerOfAt(tokenId, blockNumber);
    }
}

/// @notice Mock 721 tiers hook for testing.
contract MockHook {
    MockStore public immutable _store;
    MockCheckpoints public _checkpoints;

    mapping(uint256 tokenId => address owner) public owners;
    mapping(uint256 tokenId => mapping(uint256 blockNumber => address owner)) public historicalOwnerOf;

    constructor(MockStore store) {
        _store = store;
        _checkpoints = new MockCheckpoints(store, address(this));
    }

    function STORE() external view returns (MockStore) {
        return _store;
    }

    function CHECKPOINTS() external view returns (MockCheckpoints) {
        return _checkpoints;
    }

    function checkpoints() external view returns (MockCheckpoints) {
        return _checkpoints;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = owners[tokenId];
        require(owner != address(0), "ERC721: invalid token ID");
        return owner;
    }

    function ownerOfAt(uint256 tokenId, uint256 blockNumber) external view returns (address) {
        address historicalOwner = historicalOwnerOf[tokenId][blockNumber];
        if (historicalOwner != address(0)) return historicalOwner;

        uint256 mintBlock = _store.mintBlockOf(address(this), tokenId);
        if (mintBlock != 0 && mintBlock > blockNumber) return address(0);
        return owners[tokenId];
    }

    function setOwner(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
    }

    function setHistoricalOwner(uint256 tokenId, uint256 blockNumber, address owner) external {
        historicalOwnerOf[tokenId][blockNumber] = owner;
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
    mapping(address hook => mapping(uint256 tokenId => uint256)) public mintBlockOf;

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

    function setMintBlock(address hook, uint256 tokenId, uint256 blockNum) external {
        mintBlockOf[hook][tokenId] = blockNum;
    }
}

contract JB721DistributorTest is Test {
    JB721Distributor distributor;
    MockToken rewardToken;
    MockToken2 rewardToken2;
    MockHook hook;
    MockStore store;
    MockDirectory directory;
    MockJBTokens jbTokens;
    MockJBController burnController;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    uint256 constant PROJECT_ID = 1;
    uint256 constant ROUND_DURATION = 100; // 100 seconds per round.
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

        // Register this test contract as a terminal for PROJECT_ID so processSplitWith works.
        directory.setTerminal(PROJECT_ID, address(this), true);

        rewardToken = new MockToken();
        rewardToken2 = new MockToken2();
        jbTokens.setToken(1, IJBToken(address(rewardToken)));
        jbTokens.setToken(2, IJBToken(address(rewardToken2)));

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
                encodedIpfsUri: bytes32(0),
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
                encodedIpfsUri: bytes32(0),
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
    // Helpers
    // =====================================================================

    /// @notice Advance to 1 second after the start of the given round, and advance block number too.
    function _advanceToRound(uint256 round) internal {
        uint256 targetTimestamp = distributor.roundStartTimestamp(round) + 1;
        // Test helper only moves time forward to the requested round boundary.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < targetTimestamp) {
            vm.warp(targetTimestamp);
        }
        // Also advance block number so getPastVotes works with past blocks.
        vm.roll(block.number + 1);
    }

    function _fundHook(uint256 amount) internal {
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);
        distributor.fund(address(hook), IERC20(address(rewardToken)), amount);
    }

    function _fundExpiringHook(uint256 amount, uint48 claimDuration) internal {
        if (distributor.CLAIM_DURATION() != claimDuration) {
            distributor = new JB721Distributor(
                IJBDirectory(address(directory)),
                IJBController(address(burnController)),
                IREVLoans(address(0)),
                IREVOwner(address(0)),
                ROUND_DURATION,
                VESTING_ROUNDS,
                claimDuration
            );
        }

        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);
        distributor.fund(address(hook), IERC20(address(rewardToken)), amount);
    }

    function _advanceToNextRound() internal {
        _advanceToRound(distributor.currentRound() + 1);
    }

    function _singleTokenId(uint256 tokenId) internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
    }

    function _duplicateTokenIds(uint256 tokenId) internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](3);
        tokenIds[0] = tokenId;
        tokenIds[1] = tokenId;
        tokenIds[2] = tokenId;
    }

    function _singleRewardToken() internal view returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));
    }

    function _singleRound(uint256 round) internal pure returns (uint256[] memory rounds) {
        rounds = new uint256[](1);
        rounds[0] = round;
    }

    function _beginVestingFor(uint256 tokenId, IERC20[] memory tokens) internal {
        address owner = hook.owners(tokenId);
        vm.prank(owner);
        distributor.beginVesting(address(hook), _singleTokenId(tokenId), tokens);
    }

    function _beginVestingFor(address hookAddress, uint256 tokenId, IERC20[] memory tokens, address owner) internal {
        vm.prank(owner);
        distributor.beginVesting(hookAddress, _singleTokenId(tokenId), tokens);
    }

    function _beginVestingFor(address owner, uint256[] memory tokenIds, IERC20[] memory tokens) internal {
        vm.prank(owner);
        distributor.beginVesting(address(hook), tokenIds, tokens);
    }

    function _beginVestingBoth() internal {
        _advanceToNextRound();
        IERC20[] memory tokens = _singleRewardToken();
        _beginVestingFor(1, tokens);
        _beginVestingFor(2, tokens);
    }

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

    // =====================================================================
    // Constructor
    // =====================================================================

    function test_constructor() public view {
        assertEq(distributor.ROUND_DURATION(), ROUND_DURATION);
        assertEq(distributor.VESTING_ROUNDS(), VESTING_ROUNDS);
        assertEq(distributor.STARTING_TIMESTAMP(), block.timestamp);
        assertEq(distributor.MAX_SHARE(), MAX_SHARE);
    }

    // =====================================================================
    // View functions
    // =====================================================================

    function test_currentRound() public view {
        assertEq(distributor.currentRound(), 0);
    }

    function test_currentRound_afterWarping() public {
        vm.warp(block.timestamp + ROUND_DURATION);
        assertEq(distributor.currentRound(), 1);

        vm.warp(block.timestamp + ROUND_DURATION * 3);
        assertEq(distributor.currentRound(), 4);
    }

    function test_roundStartTimestamp() public view {
        assertEq(distributor.roundStartTimestamp(0), distributor.STARTING_TIMESTAMP());
        assertEq(distributor.roundStartTimestamp(1), distributor.STARTING_TIMESTAMP() + ROUND_DURATION);
        assertEq(distributor.roundStartTimestamp(5), distributor.STARTING_TIMESTAMP() + ROUND_DURATION * 5);
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

        _advanceToRound(2);

        // Claim happened in round 1, so round 2 is 25% vested.
        assertEq(distributor.collectableFor(address(hook), 1, IERC20(address(rewardToken))), 62.5 ether);
    }

    function test_collectableFor_atFull() public {
        _fundHook(1000 ether);
        _beginVestingBoth();

        _advanceToRound(1 + VESTING_ROUNDS);

        // lockedShare = 0. collectableFor = 250e18.
        assertEq(distributor.collectableFor(address(hook), 1, IERC20(address(rewardToken))), 250 ether);
        assertEq(distributor.collectableFor(address(hook), 2, IERC20(address(rewardToken))), 500 ether);
    }

    function test_snapshotAtRoundOf() public {
        _fundHook(1000 ether);

        (uint256 amount,,,, uint256 totalStake) =
            distributor.rewardRoundOf(address(hook), IERC20(address(rewardToken)), 0);
        assertEq(amount, 1000 ether);
        assertEq(totalStake, 400);
    }

    function test_vestingDataOf() public {
        _fundHook(1000 ether);
        _beginVestingBoth();

        (uint256 releaseRound, uint256 amount, uint256 shareClaimed) =
            distributor.vestingDataOf(address(hook), 1, IERC20(address(rewardToken)), 0);
        assertEq(releaseRound, 1 + VESTING_ROUNDS); // claimed in round 1.
        assertEq(amount, 250 ether);
        assertEq(shareClaimed, 0);
    }

    function test_latestVestedIndexOf() public {
        _fundHook(1000 ether);
        _beginVestingBoth();

        assertEq(distributor.latestVestedIndexOf(address(hook), 1, IERC20(address(rewardToken))), 0);

        // Collect fully -> latestVestedIndex should advance.
        _advanceToRound(1 + VESTING_ROUNDS);
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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);
        assertEq(distributor.claimedFor(address(hook), 1, nativeToken), 25 ether);

        // Advance past full vesting.
        _advanceToRound(1 + VESTING_ROUNDS);

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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Only token 1 vesting: 250 ether.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 250 ether);
    }

    function test_beginVesting_alreadyVesting_skips() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Second call in same round should silently skip (not revert).
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Only one vesting entry should exist.
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 250 ether);
    }

    function test_beginVesting_nextRound_succeeds() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Move to next round, add more funds, should succeed.
        _fundHook(500 ether);
        _advanceToNextRound();
        vm.prank(alice);
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

        // Add more rewards in the same funding round.
        _fundHook(500 ether);

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds1, tokens);

        // Second call in same claim round with different tokenId uses the same historical reward round.
        uint256[] memory tokenIds2 = new uint256[](1);
        tokenIds2[0] = 2;

        vm.prank(bob);
        distributor.beginVesting(address(hook), tokenIds2, tokens);

        // Both fundings in round 0 share the same snapshot and reward pot.
        // Token 1: 375e18, Token 2: 750e18. Total = 1125e18.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 1125 ether);
    }

    function test_beginVesting_emitsClaimedEvent() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        vm.expectEmit(true, true, false, true);
        emit IJBDistributor.Claimed(
            address(hook), 1, IERC20(address(rewardToken)), 250 ether, 1 + VESTING_ROUNDS, alice
        );

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);
    }

    // =====================================================================
    // poke
    // =====================================================================

    function test_poke_recordsSnapshotBlock() public {
        _advanceToRound(1);

        uint256 expectedBlock = block.number - 1;
        distributor.poke();

        assertEq(distributor.roundSnapshotBlock(1), expectedBlock);
    }

    function test_poke_emitsEvent() public {
        _advanceToRound(1);

        vm.expectEmit(true, false, false, true);
        emit IJBDistributor.RoundSnapshotRecorded(1, block.number - 1, address(this));

        distributor.poke();
    }

    function test_poke_idempotent() public {
        _advanceToRound(1);

        distributor.poke();
        uint256 firstSnapshot = distributor.roundSnapshotBlock(1);

        // Advance block but stay in same round.
        vm.roll(block.number + 10);

        distributor.poke();
        uint256 secondSnapshot = distributor.roundSnapshotBlock(1);

        assertEq(firstSnapshot, secondSnapshot, "Poke should be idempotent within a round");
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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        _advanceToRound(1 + VESTING_ROUNDS);

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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Warp forward 2 of 4 rounds (50%).
        _advanceToRound(3);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        // Entry 0 (250e18, release=5): 50% unlocked → 125 ether.
        assertEq(rewardToken.balanceOf(alice), 125 ether);

        // Warp forward remaining 2 rounds.
        _advanceToRound(1 + VESTING_ROUNDS);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        // Entry 0 remaining: 125 ether.
        assertEq(rewardToken.balanceOf(alice), 250 ether);
    }

    function test_collectVestedRewards_quarterVesting() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Warp forward 1 of 4 rounds (25%).
        _advanceToRound(2);

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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Warp forward 3 of 4 rounds (75%).
        _advanceToRound(4);

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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);
        _advanceToRound(1 + VESTING_ROUNDS);

        vm.prank(bob);
        vm.expectPartialRevert(JBDistributor.JBDistributor_NoAccess.selector);
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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);
        _advanceToRound(1 + VESTING_ROUNDS);

        vm.expectEmit(true, true, false, true);
        emit IJBDistributor.Collected(
            address(hook), 1, IERC20(address(rewardToken)), 250 ether, 1 + VESTING_ROUNDS, alice
        );

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);
    }

    function test_collectVestedRewards_differentBeneficiary() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);
        _advanceToRound(1 + VESTING_ROUNDS);

        // Alice sends to charlie.
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, charlie);

        assertEq(rewardToken.balanceOf(charlie), 250 ether);
        assertEq(rewardToken.balanceOf(alice), 0);
    }

    // =====================================================================
    // Auto-vest on collect
    // =====================================================================

    function test_autoVest_collectWithoutBeginVesting() public {
        _fundHook(1000 ether);

        // Advance past full vesting WITHOUT calling beginVesting.
        _advanceToRound(1 + VESTING_ROUNDS);

        // Alice calls collectVestedRewards directly — auto-vest should create a vesting entry.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        // Auto-vest happened for the current round. Since it just started vesting, nothing is unlocked yet.
        uint256 claimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));
        assertEq(claimed, 250 ether, "Auto-vest should have created a vesting entry");
    }

    function test_autoVest_doubleCollectInSameRound_noRevert() public {
        _fundHook(1000 ether);
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // First collect auto-vests.
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        // Second collect in same round should not revert (skips auto-vest since already vested).
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);
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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 250 ether);

        _advanceToRound(1 + VESTING_ROUNDS);
        hook.burn(1);

        distributor.releaseForfeitedRewards(address(hook), tokenIds, tokens, alice);

        // Vesting amount decremented, tokens burned instead of sent.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 0);
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 750 ether);
        assertEq(rewardToken.balanceOf(address(distributor)), 750 ether);
        assertEq(rewardToken.totalSupply(), 750 ether);
        assertEq(rewardToken.balanceOf(alice), 0);
    }

    function test_releaseForfeitedRewards_partialVesting() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Warp forward 2 of 4 rounds.
        _advanceToRound(3);
        hook.burn(1);

        distributor.releaseForfeitedRewards(address(hook), tokenIds, tokens, alice);

        // lockedShare = 50000. claimAmount = mulDiv(250e18, 50000, 100000) = 125e18.
        // totalVestingAmountOf decreased by 125e18.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 125 ether);
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 875 ether);
        assertEq(rewardToken.balanceOf(address(distributor)), 875 ether);
        assertEq(rewardToken.totalSupply(), 875 ether);
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
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), _singleTokenId(1), tokens);

        // Only token 1 should vest. Total stake = (2)*100 = 200 (burned excluded).
        // Token 1 stake = 100 → 100/200 = 50% of 1000 = 500 ether.
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 1000 ether);
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 500 ether);

        // Next round should work fine — no underflow.
        _fundHook(1 ether);
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), _singleTokenId(1), tokens);
    }

    function test_releaseForfeitedRewards_notBurned_reverts() public {
        _fundHook(1000 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        vm.expectPartialRevert(JBDistributor.JBDistributor_NoAccess.selector);
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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Token 1 share = 100/400 = 25%.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 250 ether);
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken2))), 125 ether);

        _advanceToRound(1 + VESTING_ROUNDS);

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
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Token 1 gets 250e18 from round 0.

        // Move to round 1: fund 400 more and vest.
        _fundHook(400 ether);
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Token 1 gets 25% of the round 1 funding, or 100e18.

        // Move past all vesting.
        _advanceToRound(2 + VESTING_ROUNDS);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        assertEq(rewardToken.balanceOf(alice), 250 ether + 100 ether);
    }

    function test_delayedClaim_cumulativeRewardsStartVestingWhenClaimed() public {
        uint256[] memory tokenIds = _singleTokenId(1);
        IERC20[] memory tokens = _singleRewardToken();

        // Round 0 funding belongs to round 0.
        _fundHook(1000 ether);

        // Round 1 funding belongs to round 1.
        _advanceToRound(1);
        _fundHook(400 ether);

        // Alice first shows up in round 2, so both completed reward rounds start vesting now.
        _advanceToRound(2);
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 350 ether);

        (uint256 releaseRound, uint256 amount, uint256 shareClaimed) =
            distributor.vestingDataOf(address(hook), 1, IERC20(address(rewardToken)), 0);
        assertEq(releaseRound, 2 + VESTING_ROUNDS);
        assertEq(amount, 350 ether);
        assertEq(shareClaimed, 0);
        assertEq(distributor.collectableFor(address(hook), 1, IERC20(address(rewardToken))), 0);

        _advanceToRound(2 + VESTING_ROUNDS);
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        assertEq(rewardToken.balanceOf(alice), 350 ether);
    }

    function test_currentRoundRewardsExcludedUntilNextRound() public {
        uint256[] memory tokenIds = _singleTokenId(1);
        IERC20[] memory tokens = _singleRewardToken();

        _fundHook(1000 ether);

        _advanceToRound(1);
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 250 ether);

        // Funding in round 1 is not claimable during round 1.
        _fundHook(400 ether);
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 250 ether);

        _advanceToRound(2);
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 350 ether);
    }

    function test_expiringRewards_claimBeforeDeadlineStartsVesting() public {
        uint48 claimDuration = 50;
        _fundExpiringHook(1000 ether, claimDuration);

        (uint256 amount,, uint256 claimedAmount, uint256 claimDeadline, uint256 totalStake) =
            distributor.rewardRoundOf(address(hook), IERC20(address(rewardToken)), 0);
        assertEq(amount, 1000 ether);
        assertEq(claimedAmount, 0);
        assertEq(claimDeadline, distributor.roundStartTimestamp(1) + claimDuration);
        assertEq(totalStake, 400);

        _advanceToRound(1);
        vm.prank(alice);
        distributor.beginVesting(address(hook), _singleTokenId(1), _singleRewardToken());

        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 250 ether);

        (,, claimedAmount,,) = distributor.rewardRoundOf(address(hook), IERC20(address(rewardToken)), 0);
        assertEq(claimedAmount, 250 ether);
    }

    function test_expiringRewards_permissionlessBurnAfterDeadline() public {
        uint48 claimDuration = 10;
        _fundExpiringHook(1000 ether, claimDuration);

        vm.warp(distributor.roundStartTimestamp(1) + claimDuration);
        vm.roll(block.number + 1);

        vm.prank(charlie);
        uint256 burned = distributor.burnExpiredRewards({
            hook: address(hook), token: IERC20(address(rewardToken)), rounds: _singleRound(0)
        });

        assertEq(burned, 1000 ether);
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 0);
        assertEq(rewardToken.balanceOf(address(distributor)), 0);
        assertEq(rewardToken.totalSupply(), 0);

        vm.prank(alice);
        distributor.beginVesting(address(hook), _singleTokenId(1), _singleRewardToken());

        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 0);
    }

    function test_expiringRewards_partialClaimThenBurnsOnlyRemainder() public {
        uint48 claimDuration = 50;
        _fundExpiringHook(1000 ether, claimDuration);

        _advanceToRound(1);
        vm.prank(alice);
        distributor.beginVesting(address(hook), _singleTokenId(1), _singleRewardToken());

        vm.warp(distributor.roundStartTimestamp(1) + claimDuration);
        vm.roll(block.number + 1);

        vm.prank(charlie);
        uint256 burned = distributor.burnExpiredRewards({
            hook: address(hook), token: IERC20(address(rewardToken)), rounds: _singleRound(0)
        });

        assertEq(burned, 750 ether);
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 250 ether);
        assertEq(rewardToken.balanceOf(address(distributor)), 250 ether);
        assertEq(rewardToken.totalSupply(), 250 ether);

        vm.prank(bob);
        distributor.beginVesting(address(hook), _singleTokenId(2), _singleRewardToken());

        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(rewardToken))), 0);
    }

    function test_expiringRewards_lateClaimBurnsExpiredRound() public {
        uint48 claimDuration = 10;
        _fundExpiringHook(1000 ether, claimDuration);

        vm.warp(distributor.roundStartTimestamp(1) + claimDuration);
        vm.roll(block.number + 1);

        vm.prank(alice);
        distributor.beginVesting(address(hook), _singleTokenId(1), _singleRewardToken());

        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 0);
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 0);
        assertEq(rewardToken.balanceOf(address(distributor)), 0);
        assertEq(rewardToken.totalSupply(), 0);
    }

    function test_delayedClaimAfterTransferUsesHistoricalSnapshotOwnerVotes() public {
        uint256[] memory tokenIds = _singleTokenId(1);
        IERC20[] memory tokens = _singleRewardToken();

        hook.CHECKPOINTS().setVotesOverride(alice, 100);
        hook.CHECKPOINTS().setVotesOverride(charlie, 0);

        _fundHook(1000 ether);
        (, uint256 snapshotBlock,,,) = distributor.rewardRoundOf(address(hook), IERC20(address(rewardToken)), 0);
        hook.setHistoricalOwner(1, snapshotBlock, alice);

        // The NFT transfers before anyone claims, so the current owner is the only account authorized to claim.
        hook.setOwner(1, charlie);

        _advanceToRound(1);

        vm.prank(alice);
        vm.expectPartialRevert(JBDistributor.JBDistributor_NoAccess.selector);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        vm.prank(charlie);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // The amount proves the claim used Alice's snapshot votes, not Charlie's current zero votes.
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 250 ether);
    }

    function test_beginVesting_duplicateTokenIdsRevertsBeforeConsumingSiblingRewards() public {
        uint256 siblingTokenId = 3;
        IERC20[] memory tokens = _singleRewardToken();

        store.setTokenTier(siblingTokenId, 1);
        hook.setOwner(2, alice);
        hook.setOwner(siblingTokenId, alice);
        hook.CHECKPOINTS().setVotesOverride(alice, 400);

        _fundHook(1600 ether);
        (, uint256 snapshotBlock,,,) = distributor.rewardRoundOf(address(hook), IERC20(address(rewardToken)), 0);

        hook.setHistoricalOwner(1, snapshotBlock, alice);
        hook.setHistoricalOwner(2, snapshotBlock, alice);
        hook.setHistoricalOwner(siblingTokenId, snapshotBlock, alice);

        // After the reward snapshot, Alice sells token 1 to Charlie and the sibling NFTs to Bob.
        hook.setOwner(1, charlie);
        hook.setOwner(2, bob);
        hook.setOwner(siblingTokenId, bob);

        _advanceToRound(1);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(JB721Distributor.JB721Distributor_DuplicateTokenId.selector, 1));
        distributor.beginVesting(address(hook), _duplicateTokenIds(1), tokens);

        uint256[] memory bobTokenIds = new uint256[](2);
        bobTokenIds[0] = 2;
        bobTokenIds[1] = siblingTokenId;

        vm.prank(bob);
        distributor.beginVesting(address(hook), bobTokenIds, tokens);

        // Bob's sibling NFTs keep their full historical claims because Charlie's duplicate batch never consumed them.
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 0);
        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(rewardToken))), 800 ether);
        assertEq(distributor.claimedFor(address(hook), siblingTokenId, IERC20(address(rewardToken))), 400 ether);
    }

    function test_collectVestedRewards_duplicateTokenIdsReverts() public {
        _fundHook(1000 ether);
        _advanceToRound(1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(JB721Distributor.JB721Distributor_DuplicateTokenId.selector, 1));
        distributor.collectVestedRewards(address(hook), _duplicateTokenIds(1), _singleRewardToken(), alice);
    }

    function test_lateMintCannotClaimHistoricalRewardRound() public {
        uint256 lateTokenId = 3;
        store.setTokenTier(lateTokenId, 1);

        _fundHook(1000 ether);
        (, uint256 snapshotBlock,,,) = distributor.rewardRoundOf(address(hook), IERC20(address(rewardToken)), 0);

        hook.setOwner(lateTokenId, charlie);
        store.setMintBlock(address(hook), lateTokenId, snapshotBlock + 1);

        _advanceToRound(1);

        vm.prank(charlie);
        distributor.beginVesting(address(hook), _singleTokenId(lateTokenId), _singleRewardToken());

        assertEq(distributor.claimedFor(address(hook), lateTokenId, IERC20(address(rewardToken))), 0);
    }

    function test_ownerVotingCapPersistsAcrossSeparateDelayedClaims() public {
        IERC20[] memory tokens = _singleRewardToken();

        hook.setOwner(2, alice);
        hook.CHECKPOINTS().setVotesOverride(alice, 100);
        hook.CHECKPOINTS().setTotalSupplyOverride(100);

        _fundHook(1000 ether);
        _advanceToRound(1);

        vm.prank(alice);
        distributor.beginVesting(address(hook), _singleTokenId(1), tokens);
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 1000 ether);

        vm.prank(alice);
        distributor.beginVesting(address(hook), _singleTokenId(2), tokens);

        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(rewardToken))), 0);
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 1000 ether);
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

        // Add more funds in the same reward round.
        _fundHook(500 ether);

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds1, tokens);

        // Second vesting in the same claim round reuses the historical reward round.
        vm.prank(bob);
        distributor.beginVesting(address(hook), tokenIds2, tokens);

        // Both fundings share the round 0 reward pot.
        // Token 1: 375e18, Token 2: 750e18. Total = 1125e18.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 1125 ether);

        (uint256 amount,,,,) = distributor.rewardRoundOf(address(hook), IERC20(address(rewardToken)), 0);
        assertEq(amount, 1500 ether);
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
        _advanceToRound(2);
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

        _advanceToRound(1 + VESTING_ROUNDS);

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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 totalClaimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));

        _advanceToRound(1 + rounds);

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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 totalClaimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));

        _advanceToRound(1 + VESTING_ROUNDS);

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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        _advanceToRound(3);

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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        uint256 totalClaimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));

        // Collect at each round.
        for (uint256 r = 1; r <= VESTING_ROUNDS; r++) {
            _advanceToRound(1 + r);
            vm.prank(alice);
            distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);
        }

        assertEq(rewardToken.balanceOf(alice), totalClaimed);
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
                encodedIpfsUri: bytes32(0),
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

        // Should revert when no token IDs are provided.
        vm.expectPartialRevert(JBDistributor.JBDistributor_EmptyTokenIds.selector);
        distributor.beginVesting(address(hook), tokenIds, tokens);
    }

    function test_beginVesting_emptyTokens() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](0);

        // Should succeed with no-op for outer loop.
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);
    }

    function test_collectVestedRewards_emptyArrays() public {
        uint256[] memory tokenIds = new uint256[](0);
        IERC20[] memory tokens = new IERC20[](0);

        // Should revert when no token IDs are provided.
        vm.expectPartialRevert(JBDistributor.JBDistributor_EmptyTokenIds.selector);
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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);
        _advanceToRound(1 + VESTING_ROUNDS);

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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);
        _advanceToRound(1 + VESTING_ROUNDS);

        // Transfer token 1 from alice to charlie.
        hook.setOwner(1, charlie);

        // Alice can no longer collect.
        vm.prank(alice);
        vm.expectPartialRevert(JBDistributor.JBDistributor_NoAccess.selector);
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
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Round 1: vest
        _fundHook(400 ether);
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Round 2: vest
        _fundHook(200 ether);
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Warp past all vesting (round 3 + 4 = round 7 releases last entry).
        _advanceToRound(3 + VESTING_ROUNDS);

        uint256 totalClaimed = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        assertEq(rewardToken.balanceOf(alice), totalClaimed);
        assertEq(distributor.latestVestedIndexOf(address(hook), 1, IERC20(address(rewardToken))), 3);
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 0);
    }

    function test_threeVestingEntries_partialCollect_skipsLockedEntries() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // Round 0 funding -> claim in round 1 -> releaseRound = 5
        _fundHook(1000 ether);
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);
        uint256 claimed0 = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));

        // Round 1 funding -> claim in round 2 -> releaseRound = 6
        _fundHook(400 ether);
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Round 2 funding -> claim in round 3 -> releaseRound = 7
        _fundHook(200 ether);
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Record total claimed before any collection.
        uint256 totalClaimedBefore = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));

        // Collect at round 5: entry[0] fully vested, entry[1] partially, entry[2] more locked.
        _advanceToRound(5);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        uint256 firstCollect = rewardToken.balanceOf(alice);
        assertGt(firstCollect, 0);
        assertGe(firstCollect, claimed0);

        // Collect at round 6: entry[1] fully vests, entry[2] partially.
        _advanceToRound(6);
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        uint256 secondCollect = rewardToken.balanceOf(alice);
        assertGt(secondCollect, firstCollect);

        // Collect at round 7: entry[2] fully vests.
        _advanceToRound(7);
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        assertEq(rewardToken.balanceOf(alice), totalClaimedBefore);
        assertEq(distributor.latestVestedIndexOf(address(hook), 1, IERC20(address(rewardToken))), 3);
    }

    /// @notice collectVestedRewards now matches collectableFor even with multiple stacked entries.
    function test_collectMatchesPreviewWithStackedEntries() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _fundHook(1000 ether);
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        _fundHook(400 ether);
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        _fundHook(200 ether);
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        _advanceToRound(5);

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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Partial collect at 50%.
        _advanceToRound(3);
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);
        assertEq(rewardToken.balanceOf(alice), 125 ether);

        uint256 vestingAfterPartial = distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken)));
        assertEq(vestingAfterPartial, 125 ether);

        // Burn and release remaining forfeited rewards.
        hook.burn(1);

        _advanceToRound(5);
        distributor.releaseForfeitedRewards(address(hook), tokenIds, tokens, address(0));

        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 0);
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 750 ether);
        assertEq(rewardToken.balanceOf(address(distributor)), 750 ether);
        assertEq(rewardToken.totalSupply(), 875 ether);
        // Alice keeps what she collected, no more sent.
        assertEq(rewardToken.balanceOf(alice), 125 ether);
    }

    // =====================================================================
    // Forfeited tokens burn
    // =====================================================================

    function test_forfeitedTokensBurn() public {
        _fundHook(1000 ether);
        _beginVestingBoth();

        // Burn token 1 and forfeit after full vest.
        _advanceToRound(1 + VESTING_ROUNDS);
        hook.burn(1);
        store.setBurnedFor(1, 1);

        uint256[] memory burnedIds = new uint256[](1);
        burnedIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.releaseForfeitedRewards(address(hook), burnedIds, tokens, address(0));

        // After forfeiture: token 1's 250 tokens are burned, token 2's 500 tokens remain vesting.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 500 ether);
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 750 ether);
        assertEq(rewardToken.balanceOf(address(distributor)), 750 ether);
        assertEq(rewardToken.totalSupply(), 750 ether);
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
                encodedIpfsUri: bytes32(0),
                category: 0,
                discountPercent: 0,
                flags: flags,
                splitPercent: 0,
                resolvedUri: ""
            })
        );

        _fundHook(1000 ether);
        _beginVestingBoth();

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

        _advanceToRound(1 + VESTING_ROUNDS);

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

        _advanceToRound(1 + VESTING_ROUNDS);

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
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        (uint256 amount0,,,,) = distributor.rewardRoundOf(address(hook), IERC20(address(rewardToken)), 0);
        assertEq(amount0, 1000 ether);

        // Round 1 funding records a separate reward round.
        _fundHook(500 ether);
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        (uint256 amount1,,,,) = distributor.rewardRoundOf(address(hook), IERC20(address(rewardToken)), 1);
        assertEq(amount1, 500 ether);
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
        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        _advanceToRound(1 + VESTING_ROUNDS);

        // Set up reentrancy: on transfer, the token calls collectVestedRewards again.
        maliciousToken.setReentrancyTarget(address(hook), tokenIds, tokens, alice);

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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        _advanceToRound(1 + rounds);

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
        _beginVestingBoth();

        // Round 1.
        _fundHook(fund2);
        _beginVestingBoth();

        // Full vest.
        _advanceToRound(2 + VESTING_ROUNDS);

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
                encodedIpfsUri: bytes32(0),
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

        _advanceToNextRound();
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        // Vest on hook2.
        vm.prank(charlie);
        distributor.beginVesting(address(hook2), tokenIds, tokens);

        // Vesting amounts are isolated.
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 250 ether);
        assertEq(distributor.totalVestingAmountOf(address(hook2), IERC20(address(rewardToken))), 500 ether);

        // Collect from hook2 -- should not affect hook1.
        _advanceToRound(1 + VESTING_ROUNDS);
        vm.prank(charlie);
        distributor.collectVestedRewards(address(hook2), tokenIds, tokens, charlie);

        assertEq(rewardToken.balanceOf(charlie), 500 ether);
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), 1000 ether);
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))), 250 ether);
    }

    // =====================================================================
    // Split Hook
    // =====================================================================

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

        _beginVestingBoth();

        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 25 ether);
        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(rewardToken))), 50 ether);
    }

    function test_processSplitWith_afterDirectDustFundingUsesFixedClaimDuration() public {
        uint48 claimDuration = 50;
        uint256 splitAmount = 100 ether;

        distributor = new JB721Distributor(
            IJBDirectory(address(directory)),
            IJBController(address(burnController)),
            IREVLoans(address(0)),
            IREVOwner(address(0)),
            ROUND_DURATION,
            VESTING_ROUNDS,
            claimDuration
        );

        rewardToken.mint(charlie, 1);
        vm.startPrank(charlie);
        rewardToken.approve(address(distributor), 1);
        distributor.fund(address(hook), IERC20(address(rewardToken)), 1);
        vm.stopPrank();

        rewardToken.mint(address(this), splitAmount);
        rewardToken.approve(address(distributor), splitAmount);
        distributor.processSplitWith(_splitContext(address(rewardToken), splitAmount));

        (uint256 amount,,, uint256 deadline,) =
            distributor.rewardRoundOf(address(hook), IERC20(address(rewardToken)), 0);

        assertEq(amount, splitAmount + 1, "dust and split funding share one bucket");
        assertEq(deadline, distributor.roundStartTimestamp(1) + claimDuration, "deadline is contract-fixed");
    }

    /// @notice supportsInterface returns true for IJBSplitHook, IJB721Distributor, and IERC165.
    function test_supportsInterface() public view {
        assertTrue(distributor.supportsInterface(type(IJBSplitHook).interfaceId));
        assertTrue(distributor.supportsInterface(type(IJB721Distributor).interfaceId));
        assertTrue(distributor.supportsInterface(type(IERC165).interfaceId));
        // Random interface should return false.
        assertFalse(distributor.supportsInterface(0xdeadbeef));
    }

    /// @notice processSplitWith with allowance credits balance (terminal/controller pull pattern).
    function test_processSplitWith_erc20_noAllowance_creditsBalance() public {
        uint256 amount = 10 ether;
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);

        distributor.processSplitWith(_splitContext(address(rewardToken), amount));
        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), amount);
    }

    /// @notice Controller pattern: controller approves and processSplitWith pulls tokens.
    function test_processSplitWith_controllerPattern() public {
        // Register this test as controller (not just terminal) for the controller path.
        directory.setTerminal(PROJECT_ID, address(this), false);
        directory.setController(PROJECT_ID, address(this));

        uint256 amount = 50 ether;
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);

        distributor.processSplitWith(_splitContext(address(rewardToken), amount));

        assertEq(distributor.balanceOf(address(hook), IERC20(address(rewardToken))), amount);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        _advanceToNextRound();
        vm.prank(alice);
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
        MockStore store2 = new MockStore();
        MockHook hook2 = new MockHook(store2);

        uint256 amount = 100 ether;
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);

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

        vm.expectPartialRevert(JB721Distributor.JB721Distributor_Unauthorized.selector);
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
        bool result = super.transfer(to, amount);

        if (reentrancyArmed) {
            reentrancyArmed = false;
            try JBDistributor(distributor)
                .collectVestedRewards(reentrantHook, reentrantTokenIds, reentrantTokens, reentrantBeneficiary) {}
                catch {}
        }

        return result;
    }
}
