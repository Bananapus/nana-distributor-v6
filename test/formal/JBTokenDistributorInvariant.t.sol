// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";

import {JBTokenDistributor} from "../../src/JBTokenDistributor.sol";

/// @notice ERC-20 reward token used by the invariant harness.
contract InvRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal IVotes staking token. Holders self-delegate in setUp so they have checkpointed voting power.
contract InvVotesToken is ERC20, ERC20Votes {
    constructor() ERC20("Stake", "STK") EIP712("Stake", "1") {}

    function mint(address to, uint256 amount) external {
        _mint({account: to, value: amount});
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update({from: from, to: to, value: value});
    }
}

/// @notice Minimal JB directory used to authorize a single terminal.
contract InvDirectory {
    mapping(uint256 => mapping(address => bool)) public terminals;
    mapping(uint256 => address) public controllers;

    function setTerminal(uint256 projectId, address terminal, bool isTerminal) external {
        terminals[projectId][terminal] = isTerminal;
    }

    function isTerminalOf(uint256 projectId, IJBTerminal terminal) external view returns (bool) {
        return terminals[projectId][address(terminal)];
    }

    function controllerOf(uint256 projectId) external view returns (IERC165) {
        return IERC165(controllers[projectId]);
    }
}

/// @notice Minimal JBTokens registry.
contract InvTokens {
    mapping(IJBToken => uint256) public projectIdOf;
    mapping(uint256 => IJBToken) public tokenOf;
}

/// @notice Minimal JBController exposing only TOKENS() (no loans configured).
contract InvController {
    InvTokens public immutable tokens;

    constructor(InvTokens tokens_) {
        tokens = tokens_;
    }

    function TOKENS() external view returns (InvTokens) {
        return tokens;
    }
}

/// @notice Randomly sequences fund / vest / collect / time-warp operations against a single-hook,
/// single-ERC-20-token `JBTokenDistributor` (CLAIM_DURATION == 0, the no-expiry total-supply path).
contract TokenDistributorHandler is Test {
    JBTokenDistributor public distributor;
    InvRewardToken public reward;
    InvVotesToken public votes;
    address public hook;

    address public alice;
    address public bob;

    uint256 public constant ROUND_DURATION = 100;

    // Ghosts.
    uint256 public ghost_totalFunded;
    uint256 public ghost_collectedAlice;
    uint256 public ghost_collectedBob;

    mapping(uint256 tokenId => uint256 lastVestRound) public lastVestedRoundOf;

    constructor(
        JBTokenDistributor _distributor,
        InvRewardToken _reward,
        InvVotesToken _votes,
        address _alice,
        address _bob
    ) {
        distributor = _distributor;
        reward = _reward;
        votes = _votes;
        hook = address(_votes);
        alice = _alice;
        bob = _bob;
    }

    function _tokenId(address staker) internal pure returns (uint256) {
        return uint256(uint160(staker));
    }

    /// @notice Fund the default group with a bounded amount.
    function fund(uint96 rawAmount) external {
        uint256 amount = bound(rawAmount, 0.001 ether, 50 ether);
        reward.mint(address(this), amount);
        reward.approve(address(distributor), amount);
        distributor.fund(hook, IERC20(address(reward)), amount);
        ghost_totalFunded += amount;
    }

    /// @notice Advance time by 0..3 rounds and roll the block so getPastVotes has a strictly past block.
    function warp(uint8 rawRounds) external {
        uint256 rounds = bound(rawRounds, 0, 3);
        if (rounds != 0) {
            vm.warp(block.timestamp + ROUND_DURATION * rounds);
            vm.roll(block.number + 1);
        }
    }

    /// @notice Begin vesting for one staker (avoiding a double-vest within the same round).
    function beginVesting(bool whichAlice) external {
        address staker = whichAlice ? alice : bob;
        uint256 round = distributor.currentRound();
        if (lastVestedRoundOf[_tokenId(staker)] == round) return;

        uint256[] memory ids = new uint256[](1);
        ids[0] = _tokenId(staker);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));

        vm.prank(staker);
        distributor.beginVesting(hook, ids, tokens);
        lastVestedRoundOf[_tokenId(staker)] = round;
    }

    /// @notice Collect vested rewards for one staker.
    function collect(bool whichAlice) external {
        address staker = whichAlice ? alice : bob;
        uint256[] memory ids = new uint256[](1);
        ids[0] = _tokenId(staker);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));

        uint256 before = reward.balanceOf(staker);
        vm.prank(staker);
        distributor.collectVestedRewards(hook, ids, tokens, staker);
        uint256 gained = reward.balanceOf(staker) - before;

        if (whichAlice) ghost_collectedAlice += gained;
        else ghost_collectedBob += gained;
    }
}

/// @notice Stateful functional-correctness invariants for `JBTokenDistributor` (IVotes path,
/// CLAIM_DURATION == 0). Complements the existing `JB721DistributorInvariant`. Asserts the conservation
/// (D.10), no-overclaim, and `totalVestingAmountOf == Σ claimedFor` (D.6) properties from INVARIANTS.md.
contract JBTokenDistributorInvariantTest is StdInvariant, Test {
    JBTokenDistributor distributor;
    InvRewardToken reward;
    InvVotesToken votes;
    InvDirectory directory;
    InvTokens tokens;
    InvController controller;
    TokenDistributorHandler handler;

    address alice = makeAddr("inv_alice");
    address bob = makeAddr("inv_bob");

    uint256 constant ROUND_DURATION = 100;
    uint256 constant VESTING_ROUNDS = 4;

    function setUp() public {
        directory = new InvDirectory();
        tokens = new InvTokens();
        controller = new InvController(tokens);
        reward = new InvRewardToken();
        votes = new InvVotesToken();

        distributor = new JBTokenDistributor(
            IJBDirectory(address(directory)),
            IJBController(address(controller)),
            IREVLoans(address(0)),
            IREVOwner(address(0)),
            ROUND_DURATION,
            VESTING_ROUNDS,
            0 // CLAIM_DURATION == 0: rewards never expire, denominator = getPastTotalSupply.
        );

        // Mint and self-delegate so both stakers have checkpointed voting power.
        votes.mint(alice, 700 ether);
        votes.mint(bob, 300 ether);
        vm.prank(alice);
        votes.delegate(alice);
        vm.prank(bob);
        votes.delegate(bob);

        // Advance a block so the first round's snapshot (block.number - 1) sees the delegated supply.
        vm.roll(block.number + 1);

        handler = new TokenDistributorHandler(distributor, reward, votes, alice, bob);
        targetContract(address(handler));
    }

    /// @notice D.10 conservation: the distributor's tracked balance for the hook equals its real ERC-20 holdings.
    /// One hook, one ERC-20, no loans => `_balanceOf[hook][token]` must equal the contract's token balance after
    /// every randomized sequence (funding credits both, owner collections debit both in lockstep).
    function invariant_trackedBalanceMatchesActualBacking() public view {
        assertEq(
            distributor.balanceOf(address(votes), IERC20(address(reward))),
            reward.balanceOf(address(distributor)),
            "tracked balance != actual backing"
        );
    }

    /// @notice No-overclaim: total tokens collected by all stakers never exceeds total funded.
    function invariant_totalCollectedNeverExceedsFunded() public view {
        assertLe(
            handler.ghost_collectedAlice() + handler.ghost_collectedBob(),
            handler.ghost_totalFunded(),
            "collected exceeds funded"
        );
    }

    /// @notice D.6: the aggregate vesting counter equals the sum of each staker's remaining uncollected claims.
    function invariant_totalVestingMatchesRemainingClaims() public view {
        IERC20 token = IERC20(address(reward));
        uint256 remaining = distributor.claimedFor(address(votes), uint256(uint160(alice)), token)
            + distributor.claimedFor(address(votes), uint256(uint160(bob)), token);
        assertEq(distributor.totalVestingAmountOf(address(votes), token), remaining, "vesting != sum claimedFor");
    }

    /// @notice totalVestingAmountOf never exceeds the hook's tracked balance (can't owe more than is held).
    function invariant_vestingNeverExceedsBalance() public view {
        assertLe(
            distributor.totalVestingAmountOf(address(votes), IERC20(address(reward))),
            distributor.balanceOf(address(votes), IERC20(address(reward))),
            "vesting exceeds balance"
        );
    }

    /// @notice collectableFor (unlocked) never exceeds claimedFor (vesting + unlocked) for either staker.
    function invariant_collectableNeverExceedsClaimed() public view {
        IERC20 token = IERC20(address(reward));
        assertLe(
            distributor.collectableFor(address(votes), uint256(uint160(alice)), token),
            distributor.claimedFor(address(votes), uint256(uint160(alice)), token),
            "alice collectable > claimed"
        );
        assertLe(
            distributor.collectableFor(address(votes), uint256(uint160(bob)), token),
            distributor.claimedFor(address(votes), uint256(uint160(bob)), token),
            "bob collectable > claimed"
        );
    }

    /// @notice Whole-system token conservation: funded supply is split among distributor, stakers, and the handler.
    function invariant_balanceConservation() public view {
        uint256 total = reward.totalSupply();
        uint256 acc = reward.balanceOf(address(distributor)) + reward.balanceOf(alice) + reward.balanceOf(bob)
            + reward.balanceOf(address(handler));
        assertEq(acc, total, "token conservation broken");
    }
}
