// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {JBDistributor} from "../../src/JBDistributor.sol";
import {JBTokenDistributor} from "../../src/JBTokenDistributor.sol";

contract ReentrantRewardDirectory {
    mapping(uint256 projectId => address terminal) public terminalOf;

    function setTerminal(uint256 projectId, address terminal) external {
        terminalOf[projectId] = terminal;
    }

    function isTerminalOf(uint256 projectId, IJBTerminal terminal) external view returns (bool) {
        return terminalOf[projectId] == address(terminal);
    }

    function controllerOf(uint256) external pure returns (IERC165) {
        return IERC165(address(0));
    }
}

contract ReentrantRewardToken is ERC20 {
    JBTokenDistributor public distributor;
    address public reentryHook;
    uint256 public reentryAmount;
    bool public reentryEnabled;

    bool private _reentering;

    constructor() ERC20("Reentrant Reward", "RRWD") {}

    function configureReentry(
        JBTokenDistributor distributor_,
        address reentryHook_,
        uint256 reentryAmount_,
        bool reentryEnabled_
    )
        external
    {
        distributor = distributor_;
        reentryHook = reentryHook_;
        reentryAmount = reentryAmount_;
        reentryEnabled = reentryEnabled_;

        _approve(address(this), address(distributor_), type(uint256).max);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);

        if (!reentryEnabled || _reentering || to != address(distributor) || from == address(0) || amount == 0) {
            return;
        }

        _reentering = true;
        distributor.fund(reentryHook, IERC20(address(this)), reentryAmount);
        _reentering = false;
    }
}

contract ReentrantVotesToken is ERC20, ERC20Votes {
    constructor() ERC20("Stake", "STK") EIP712("Stake", "1") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}

contract ReentrantRewardFundingGuard is Test {
    JBTokenDistributor private _distributor;
    ReentrantRewardDirectory private _directory;
    ReentrantRewardToken private _reward;
    ReentrantVotesToken private _stake;
    ReentrantVotesToken private _victimStake;

    address private _attacker = makeAddr("attacker");
    address private _terminal = makeAddr("terminal");
    address private _victim = makeAddr("victim");
    address private _victimFunder = makeAddr("victimFunder");
    address private _victimHook;

    uint256 private _projectId = 1;

    function setUp() public {
        _directory = new ReentrantRewardDirectory();
        _directory.setTerminal(_projectId, _terminal);

        _distributor = new JBTokenDistributor(
            IJBDirectory(address(_directory)),
            IJBController(address(0)),
            IREVLoans(address(0)),
            IREVOwner(address(0)),
            1,
            1,
            0
        );
        _reward = new ReentrantRewardToken();
        _stake = new ReentrantVotesToken();
        _victimStake = new ReentrantVotesToken();

        _stake.mint(_attacker, 1 ether);
        vm.prank(_attacker);
        _stake.delegate(_attacker);

        _victimStake.mint(_victim, 1 ether);
        vm.prank(_victim);
        _victimStake.delegate(_victim);
        _victimHook = address(_victimStake);

        vm.roll(block.number + 1);

        _fundVictimHook();
    }

    function test_reentrantFundRevertsBeforeOverCredit() public {
        _prepareReentrantFunding(_attacker, 200 ether, 100 ether);

        vm.prank(_attacker);
        _reward.approve(address(_distributor), 200 ether);

        vm.prank(_attacker);
        vm.expectRevert(
            abi.encodeWithSelector(JBDistributor.JBDistributor_ReentrantTokenTransfer.selector, address(_reward))
        );
        _distributor.fund(address(_stake), IERC20(address(_reward)), 200 ether);

        _assertOnlyVictimBackingRemains();
    }

    function test_reentrantProcessSplitWithRevertsBeforeOverCredit() public {
        _prepareReentrantFunding(_terminal, 200 ether, 100 ether);

        JBSplit memory split = JBSplit({
            percent: 1_000_000_000,
            projectId: 0,
            beneficiary: payable(address(_stake)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(_distributor))
        });

        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(_reward), amount: 200 ether, decimals: 18, projectId: _projectId, groupId: 0, split: split
        });

        vm.prank(_terminal);
        _reward.approve(address(_distributor), 200 ether);

        vm.prank(_terminal);
        vm.expectRevert(
            abi.encodeWithSelector(JBDistributor.JBDistributor_ReentrantTokenTransfer.selector, address(_reward))
        );
        _distributor.processSplitWith(context);

        _assertOnlyVictimBackingRemains();
    }

    function _assertOnlyVictimBackingRemains() internal view {
        assertEq(_reward.balanceOf(address(_distributor)), 100 ether, "actual pool changed");
        assertEq(_distributor.balanceOf(_victimHook, IERC20(address(_reward))), 100 ether, "victim accounting changed");
        assertEq(_distributor.balanceOf(address(_stake), IERC20(address(_reward))), 0, "attacker accounting changed");
    }

    function _fundVictimHook() internal {
        _reward.mint(_victimFunder, 100 ether);
        vm.prank(_victimFunder);
        _reward.approve(address(_distributor), 100 ether);

        vm.prank(_victimFunder);
        _distributor.fund(_victimHook, IERC20(address(_reward)), 100 ether);
    }

    function _prepareReentrantFunding(address funder, uint256 outerAmount, uint256 reentryAmount) internal {
        _reward.mint(funder, outerAmount);
        _reward.mint(address(_reward), reentryAmount);
        _reward.configureReentry({
            distributor_: _distributor,
            reentryHook_: address(_stake),
            reentryAmount_: reentryAmount,
            reentryEnabled_: true
        });
    }
}
