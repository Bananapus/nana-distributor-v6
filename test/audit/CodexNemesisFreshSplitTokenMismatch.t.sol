// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {JBTokenDistributor} from "../../src/JBTokenDistributor.sol";

contract NemesisRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NemesisStakeToken is ERC20, ERC20Votes {
    constructor() ERC20("Stake", "STK") EIP712("Stake", "1") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}

contract NemesisDirectory is IJBDirectory {
    mapping(uint256 projectId => IJBTerminal terminal) public terminalOf;
    mapping(uint256 projectId => IERC165 controller) public override controllerOf;

    function setTerminal(uint256 projectId, IJBTerminal terminal) external {
        terminalOf[projectId] = terminal;
    }

    function PROJECTS() external pure returns (IJBProjects) {
        return IJBProjects(address(0));
    }

    function isAllowedToSetFirstController(address) external pure returns (bool) {
        return false;
    }

    function isTerminalOf(uint256 projectId, IJBTerminal terminal) external view returns (bool) {
        return terminalOf[projectId] == terminal;
    }

    function primaryTerminalOf(uint256, address) external pure returns (IJBTerminal) {
        return IJBTerminal(address(0));
    }

    function terminalsOf(uint256 projectId) external view returns (IJBTerminal[] memory terminals) {
        terminals = new IJBTerminal[](1);
        terminals[0] = terminalOf[projectId];
    }

    function setControllerOf(uint256, IERC165) external {}
    function setIsAllowedToSetFirstController(address, bool) external {}
    function setPrimaryTerminalOf(uint256, address, IJBTerminal) external {}
    function setTerminalsOf(uint256, IJBTerminal[] calldata) external {}
}

    contract CodexNemesisFreshSplitTokenMismatchTest is Test {
        JBTokenDistributor distributor;
        NemesisDirectory directory;
        NemesisRewardToken reward;
        NemesisStakeToken stake;

        address attacker = address(0xA11CE);
        address attackerTerminal = address(0xBEEF);
        address victimHook = address(0xCAFE);

        function setUp() public {
            directory = new NemesisDirectory();
            distributor = new JBTokenDistributor(IJBDirectory(address(directory)), 1 days, 1);
            reward = new NemesisRewardToken();
            stake = new NemesisStakeToken();

            directory.setTerminal(1, IJBTerminal(attackerTerminal));

            reward.mint(address(this), 100 ether);
            reward.approve(address(distributor), 100 ether);
            distributor.fund(victimHook, reward, 100 ether);

            stake.mint(attacker, 1 ether);
            vm.prank(attacker);
            stake.delegate(attacker);
            vm.roll(block.number + 1);
        }

        /// @notice Previously this test proved the attack worked. Now it proves the fix: sending ETH
        /// with context.token set to an ERC-20 address reverts with TokenMismatch.
        function test_authorizedTerminalCanBackFakeErc20CreditWithEthAndDrainVictimInventory() public {
            vm.deal(attackerTerminal, 50 ether);

            JBSplit memory split = JBSplit({
                percent: 0,
                projectId: 0,
                beneficiary: payable(address(stake)),
                preferAddToBalance: false,
                lockedUntil: 0,
                hook: IJBSplitHook(address(distributor))
            });
            JBSplitHookContext memory context = JBSplitHookContext({
                token: address(reward),
                amount: 50 ether,
                decimals: 18,
                projectId: 1,
                groupId: uint256(uint160(address(reward))),
                split: split
            });

            // FIX VERIFIED: The attack now reverts because context.token != NATIVE_TOKEN when msg.value != 0.
            vm.prank(attackerTerminal);
            vm.expectRevert(JBTokenDistributor.JBTokenDistributor_TokenMismatch.selector);
            distributor.processSplitWith{value: 50 ether}(context);

            // Victim's balance remains intact.
            assertEq(distributor.balanceOf(victimHook, reward), 100 ether);
        }
    }
