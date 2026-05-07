// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {JBTokenDistributor} from "../../src/JBTokenDistributor.sol";

contract RegressionDirectory {
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

contract RegressionReward is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RegressionVotes is ERC20, ERC20Votes {
    constructor() ERC20("Stake", "STK") EIP712("Stake", "1") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}

contract Regression20260505Test is Test {
    RegressionDirectory internal directory;
    RegressionReward internal reward;
    RegressionVotes internal votes;
    JBTokenDistributor internal distributor;

    address internal alice = makeAddr("alice");
    address internal victim = makeAddr("victim");
    uint256 internal constant PROJECT_ID = 1;

    function setUp() public {
        directory = new RegressionDirectory();
        reward = new RegressionReward();
        votes = new RegressionVotes();
        distributor = new JBTokenDistributor(IJBDirectory(address(directory)), 1, 3);

        directory.setController(PROJECT_ID, address(this));

        votes.mint(alice, 1 ether);
        vm.prank(alice);
        votes.delegate(alice);
        vm.roll(block.number + 1);
    }

    function test_unaccountedPrepaidCreditCanBeSweptByController() public {
        reward.mint(victim, 100 ether);
        vm.prank(victim);
        assertTrue(reward.transfer(address(distributor), 100 ether));

        assertEq(reward.balanceOf(address(distributor)), 100 ether);
        assertEq(distributor.balanceOf(address(votes), IERC20(address(reward))), 0);

        distributor.processSplitWith(
            JBSplitHookContext({
                token: address(reward),
                amount: 100 ether,
                decimals: 18,
                projectId: PROJECT_ID,
                groupId: uint256(uint160(address(reward))),
                split: JBSplit({
                    percent: 0,
                    projectId: 0,
                    beneficiary: payable(address(votes)),
                    preferAddToBalance: false,
                    lockedUntil: 0,
                    hook: distributor
                })
            })
        );

        assertEq(distributor.balanceOf(address(votes), IERC20(address(reward))), 100 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(alice));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));

        distributor.beginVesting(address(votes), tokenIds, tokens);

        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);

        vm.prank(alice);
        distributor.collectVestedRewards(address(votes), tokenIds, tokens, alice);

        assertEq(reward.balanceOf(alice), 100 ether);
    }

    function test_dustClaimableOnceFullyVested() public {
        reward.mint(address(this), 1);
        reward.approve(address(distributor), 1);
        distributor.fund(address(votes), IERC20(address(reward)), 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(alice));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));

        distributor.beginVesting(address(votes), tokenIds, tokens);

        // Round 1: partial vesting — claimAmount rounds to 0, shareClaimed stays at 0.
        vm.warp(distributor.roundStartTimestamp(1) + 1);
        vm.roll(block.number + 1);
        vm.prank(alice);
        distributor.collectVestedRewards(address(votes), tokenIds, tokens, alice);
        assertEq(reward.balanceOf(alice), 0, "dust should not transfer during partial vesting");

        // Advance past all vesting rounds so dust is fully vested.
        vm.warp(distributor.roundStartTimestamp(3) + 1);
        vm.roll(block.number + 1);
        vm.prank(alice);
        distributor.collectVestedRewards(address(votes), tokenIds, tokens, alice);

        // Dust is now claimable because shareClaimed was preserved at 0 during the partial round.
        assertEq(reward.balanceOf(alice), 1, "dust should be claimable once fully vested");
        // claimedFor returns remaining claimable, which should be 0 after full claim.
        assertEq(distributor.claimedFor(address(votes), tokenIds[0], IERC20(address(reward))), 0);
    }
}
