// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";

import {JB721Distributor} from "../../src/JB721Distributor.sol";
import {JBTokenDistributor} from "../../src/JBTokenDistributor.sol";

import {
    VotingCapMockDirectory,
    VotingCapMockHook,
    VotingCapMockRewardToken,
    VotingCapMockStore
} from "./VotingPowerCapRegression.t.sol";

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

contract RegressionRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RegressionVotesToken is ERC20, ERC20Votes {
    constructor() ERC20("StakeToken", "STK") EIP712("StakeToken", "1") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}

contract DistributorRegressionTest is Test {
    uint256 constant ROUND_DURATION = 100;
    uint256 constant VESTING_ROUNDS = 1;

    function test_721OwnerVotingCapResetsAcrossBeginVestingCalls() public {
        VotingCapMockStore store = new VotingCapMockStore();
        VotingCapMockHook hook = new VotingCapMockHook(store);
        VotingCapMockDirectory directory = new VotingCapMockDirectory();
        JB721Distributor distributor =
            new JB721Distributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);
        VotingCapMockRewardToken rewardToken = new VotingCapMockRewardToken();

        address alice = makeAddr("alice");

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
                flags: JB721TierFlags({
                    allowOwnerMint: false,
                    transfersPausable: false,
                    cantBeRemoved: false,
                    cantIncreaseDiscountPercent: false,
                    cantBuyWithCredits: false
                }),
                splitPercent: 0,
                resolvedUri: ""
            })
        );

        store.setTokenTier(1, 1);
        store.setTokenTier(2, 1);
        store.setTokenTier(3, 1);
        hook.setOwner(1, alice);
        hook.setOwner(2, alice);
        hook.setOwner(3, alice);
        hook._checkpoints().setVotesOverride(alice, 100);

        rewardToken.mint(address(this), 1500 ether);
        rewardToken.approve(address(distributor), 1500 ether);
        distributor.fund(address(hook), IERC20(address(rewardToken)), 1500 ether);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        uint256[] memory oneTokenId = new uint256[](1);
        oneTokenId[0] = 1;
        distributor.beginVesting(address(hook), oneTokenId, tokens);
        oneTokenId[0] = 2;
        distributor.beginVesting(address(hook), oneTokenId, tokens);
        oneTokenId[0] = 3;
        distributor.beginVesting(address(hook), oneTokenId, tokens);

        uint256 claimed1 = distributor.claimedFor(address(hook), 1, IERC20(address(rewardToken)));
        uint256 claimed2 = distributor.claimedFor(address(hook), 2, IERC20(address(rewardToken)));
        uint256 claimed3 = distributor.claimedFor(address(hook), 3, IERC20(address(rewardToken)));

        // FIX: With persistent consumed-votes tracking, the total claimed is now correctly
        // capped at the owner's voting power (100 votes / 150 total stake * 1500 = 1000 ether).
        assertEq(claimed1 + claimed2 + claimed3, 1000 ether);
        assertLe(claimed1 + claimed2 + claimed3, 1000 ether);
    }

    function test_processSplitWithControllerPathCanCreditUnfundedBalanceAndDrainOtherHook() public {
        RegressionDirectory directory = new RegressionDirectory();
        JBTokenDistributor distributor =
            new JBTokenDistributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);
        RegressionRewardToken rewardToken = new RegressionRewardToken();
        RegressionVotesToken attackerVotes = new RegressionVotesToken();

        address attacker = makeAddr("attacker");
        address maliciousController = makeAddr("maliciousController");
        address victimHook = makeAddr("victimHook");
        uint256 projectId = 1;

        directory.setController(projectId, maliciousController);

        rewardToken.mint(address(this), 1000 ether);
        rewardToken.approve(address(distributor), 1000 ether);
        distributor.fund(victimHook, IERC20(address(rewardToken)), 1000 ether);

        attackerVotes.mint(attacker, 1000 ether);
        vm.prank(attacker);
        attackerVotes.delegate(attacker);
        vm.roll(block.number + 1);

        JBSplit memory split = JBSplit({
            percent: 1_000_000_000,
            projectId: 0,
            beneficiary: payable(address(attackerVotes)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(distributor))
        });
        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(rewardToken),
            amount: 1000 ether,
            decimals: 18,
            projectId: projectId,
            groupId: uint256(uint160(address(rewardToken))),
            split: split
        });

        // FIX: The distributor now always pulls via transferFrom. A malicious controller
        // without tokens or allowance cannot inflate balances — the transfer reverts.
        vm.prank(maliciousController);
        vm.expectRevert();
        distributor.processSplitWith(context);

        // The victim hook's balance should remain intact.
        assertEq(distributor.balanceOf(victimHook, IERC20(address(rewardToken))), 1000 ether);
        // No balance should be credited to the attacker's hook.
        assertEq(distributor.balanceOf(address(attackerVotes), IERC20(address(rewardToken))), 0);
    }
}
