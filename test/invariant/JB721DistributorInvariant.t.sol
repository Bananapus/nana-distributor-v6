// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JB721Distributor} from "../../src/JB721Distributor.sol";

/// @notice Simple ERC20 token for invariant testing.
contract InvariantToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock 721 tiers hook for invariant testing.
contract InvariantMockHook {
    InvariantMockStore public immutable _store;

    mapping(uint256 tokenId => address owner) public owners;

    constructor(InvariantMockStore store) {
        _store = store;
    }

    function STORE() external view returns (InvariantMockStore) {
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

/// @notice Mock 721 tiers hook store for invariant testing.
contract InvariantMockStore {
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

/// @notice Mock JB directory for invariant testing.
contract InvariantMockDirectory {
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

/// @notice Handler that randomly sequences operations against the distributor.
contract DistributorHandler is Test {
    JB721Distributor public distributor;
    InvariantToken public rewardToken;
    InvariantMockHook public hook;
    InvariantMockStore public store;

    // Actors.
    address public alice;
    address public bob;

    // Ghost variables for tracking invariants.
    uint256 public ghost_totalFunded;
    uint256 public ghost_totalCollectedByAlice;
    uint256 public ghost_totalCollectedByBob;
    uint256 public ghost_vestingCalls;
    uint256 public ghost_collectCalls;
    uint256 public ghost_forfeitCalls;
    uint256 public ghost_fundCalls;
    uint256 public ghost_warpCalls;

    // Track whether tokens are burned.
    bool public token1Burned;
    bool public token2Burned;

    // Track latest round we vested in per tokenId to avoid double-vest in same round.
    mapping(uint256 tokenId => uint256 lastVestedRound) public lastVestedRoundOf;

    uint256 constant ROUND_DURATION = 100; // 100 seconds per round.

    constructor(
        JB721Distributor _distributor,
        InvariantToken _rewardToken,
        InvariantMockHook _hook,
        InvariantMockStore _store,
        address _alice,
        address _bob
    ) {
        distributor = _distributor;
        rewardToken = _rewardToken;
        hook = _hook;
        store = _store;
        alice = _alice;
        bob = _bob;
    }

    /// @notice Fund the distributor with random amount.
    function fund(uint128 rawAmount) external {
        uint256 amount = bound(rawAmount, 0.01 ether, 100 ether);
        rewardToken.mint(address(this), amount);
        rewardToken.approve(address(distributor), amount);
        distributor.fund(address(hook), IERC20(address(rewardToken)), amount);
        ghost_totalFunded += amount;
        ghost_fundCalls++;
    }

    /// @notice Advance time by random amount (0-3 rounds) and advance block number.
    function warpForward(uint8 rawRounds) external {
        uint256 rounds = bound(rawRounds, 0, 3);
        if (rounds > 0) {
            vm.warp(block.timestamp + ROUND_DURATION * rounds);
            vm.roll(block.number + 1); // Advance block for getPastVotes.
        }
        ghost_warpCalls++;
    }

    /// @notice Begin vesting for one or both tokens.
    function beginVesting(uint8 tokenSelector) external {
        uint256 currentRound = distributor.currentRound();

        // Determine which tokens to vest (skip already-vested — they'll be silently skipped anyway).
        bool vest1 = !token1Burned && (tokenSelector % 3 != 1) && lastVestedRoundOf[1] != currentRound;
        bool vest2 = !token2Burned && (tokenSelector % 3 != 0) && lastVestedRoundOf[2] != currentRound;

        if (!vest1 && !vest2) return;

        uint256 count;
        if (vest1) count++;
        if (vest2) count++;

        uint256[] memory tokenIds = new uint256[](count);
        uint256 idx;
        if (vest1) {
            tokenIds[idx++] = 1;
            lastVestedRoundOf[1] = currentRound;
        }
        if (vest2) {
            tokenIds[idx++] = 2;
            lastVestedRoundOf[2] = currentRound;
        }

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        // Only vest if there's a balance to distribute.
        if (
            distributor.balanceOf(address(hook), IERC20(address(rewardToken)))
                > distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken)))
        ) {
            distributor.beginVesting(address(hook), tokenIds, tokens);
            ghost_vestingCalls++;
        }
    }

    /// @notice Collect vested rewards for alice (token 1).
    function collectAlice() external {
        if (token1Burned) return;

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        uint256 balanceBefore = rewardToken.balanceOf(alice);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        ghost_totalCollectedByAlice += rewardToken.balanceOf(alice) - balanceBefore;
        ghost_collectCalls++;
    }

    /// @notice Collect vested rewards for bob (token 2).
    function collectBob() external {
        if (token2Burned) return;

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 2;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        uint256 balanceBefore = rewardToken.balanceOf(bob);

        vm.prank(bob);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, bob);

        ghost_totalCollectedByBob += rewardToken.balanceOf(bob) - balanceBefore;
        ghost_collectCalls++;
    }

    /// @notice Burn token 1 and release forfeited rewards.
    function burnAndForfeit1() external {
        if (token1Burned) return;

        hook.burn(1);
        token1Burned = true;
        store.setBurnedFor(1, 1); // Tier 1 now has 1 burned.

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        distributor.releaseForfeitedRewards(address(hook), tokenIds, tokens, address(0));
        ghost_forfeitCalls++;
    }
}

contract JB721DistributorInvariantTest is StdInvariant, Test {
    JB721Distributor distributor;
    InvariantToken rewardToken;
    InvariantMockHook hook;
    InvariantMockStore store;
    InvariantMockDirectory directory;
    DistributorHandler handler;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant ROUND_DURATION = 100; // 100 seconds per round.
    uint256 constant VESTING_ROUNDS = 4;

    function setUp() public {
        store = new InvariantMockStore();
        hook = new InvariantMockHook(store);
        directory = new InvariantMockDirectory();

        distributor = new JB721Distributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);

        rewardToken = new InvariantToken();

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

        handler = new DistributorHandler(distributor, rewardToken, hook, store, alice, bob);

        // Target only the handler for invariant calls.
        targetContract(address(handler));

        // Seed with some initial funds so early vesting calls work.
        rewardToken.mint(address(handler), 10 ether);
        rewardToken.approve(address(distributor), type(uint256).max);
        vm.prank(address(handler));
        rewardToken.approve(address(distributor), type(uint256).max);
        handler.fund(10); // Track in ghost.
    }

    /// @notice INVARIANT: Total collected by all users never exceeds total funded.
    function invariant_totalCollectedNeverExceedsFunded() public view {
        uint256 totalCollected = handler.ghost_totalCollectedByAlice() + handler.ghost_totalCollectedByBob();
        assertLe(totalCollected, handler.ghost_totalFunded());
    }

    /// @notice INVARIANT: totalVestingAmountOf never exceeds the hook's tracked balance.
    function invariant_vestingNeverExceedsBalance() public view {
        assertLe(
            distributor.totalVestingAmountOf(address(hook), IERC20(address(rewardToken))),
            distributor.balanceOf(address(hook), IERC20(address(rewardToken)))
        );
    }

    /// @notice INVARIANT: Token balances are conserved (funded = distributor + alice + bob).
    function invariant_balanceConservation() public view {
        uint256 totalSupply = rewardToken.totalSupply();
        uint256 distributorBal = rewardToken.balanceOf(address(distributor));
        uint256 aliceBal = rewardToken.balanceOf(alice);
        uint256 bobBal = rewardToken.balanceOf(bob);
        uint256 handlerBal = rewardToken.balanceOf(address(handler));

        // All tokens must be accounted for.
        assertEq(distributorBal + aliceBal + bobBal + handlerBal, totalSupply);
    }

    /// @notice INVARIANT: collectableFor never exceeds claimedFor for any token.
    function invariant_collectableNeverExceedsClaimed() public view {
        IERC20 token = IERC20(address(rewardToken));

        if (!handler.token1Burned()) {
            assertLe(
                distributor.collectableFor(address(hook), 1, token), distributor.claimedFor(address(hook), 1, token)
            );
        }
        if (!handler.token2Burned()) {
            assertLe(
                distributor.collectableFor(address(hook), 2, token), distributor.claimedFor(address(hook), 2, token)
            );
        }
    }

    /// @notice Log call stats after invariant run.
    function invariant_callSummary() public view {
        // This invariant always passes -- it just logs the handler call distribution.
        handler.ghost_fundCalls();
        handler.ghost_vestingCalls();
        handler.ghost_collectCalls();
        handler.ghost_forfeitCalls();
        handler.ghost_warpCalls();
    }
}
