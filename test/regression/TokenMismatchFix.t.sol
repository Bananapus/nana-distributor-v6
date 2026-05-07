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
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

import {JBTokenDistributor} from "../../src/JBTokenDistributor.sol";
import {JB721Distributor} from "../../src/JB721Distributor.sol";
import {JBDistributor} from "../../src/JBDistributor.sol";

// =========================================================================
// Mock contracts
// =========================================================================

/// @notice Mock JB directory for token mismatch tests.
contract TMMockDirectory {
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

/// @notice Simple ERC20 token representing a victim's deposited ERC-20.
contract TMVictimToken is ERC20 {
    constructor() ERC20("VictimToken", "VICTIM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice ERC20Votes token for staking.
contract TMVotesToken is ERC20, ERC20Votes {
    constructor() ERC20("StakeToken", "STK") EIP712("StakeToken", "1") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}

// =========================================================================
// Test: JBTokenDistributor token mismatch vulnerability
// =========================================================================

/// @notice Proves the ETH-to-ERC20 cross-booking vulnerability is fixed in JBTokenDistributor.
/// @dev The attack: a malicious terminal sends ETH (msg.value != 0) but sets context.token to an
/// arbitrary ERC-20 address. Without the fix, the ETH amount would be credited under that ERC-20's
/// balance mapping, effectively stealing another hook's ERC-20 balance.
contract TokenMismatchTokenDistributorTest is Test {
    TMMockDirectory directory;
    TMVictimToken victimToken;
    TMVotesToken votesToken;
    JBTokenDistributor distributor;

    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");
    address terminal = makeAddr("terminal");
    address hook;
    uint256 projectId = 1;

    uint256 constant ROUND_DURATION = 100;
    uint256 constant VESTING_ROUNDS = 4;

    function setUp() public {
        directory = new TMMockDirectory();
        victimToken = new TMVictimToken();
        votesToken = new TMVotesToken();

        directory.setTerminal(projectId, terminal, true);

        distributor = new JBTokenDistributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);

        hook = address(votesToken);
    }

    /// @notice Helper to build a JBSplitHookContext.
    function _buildContext(address token, uint256 amount) internal view returns (JBSplitHookContext memory) {
        JBSplit memory split = JBSplit({
            percent: 1_000_000_000,
            projectId: 0,
            beneficiary: payable(hook),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(distributor))
        });

        return JBSplitHookContext({
            token: token, amount: amount, decimals: 18, projectId: projectId, groupId: 0, split: split
        });
    }

    /// @notice Proves the fix: sending ETH with context.token set to an ERC-20 address reverts.
    function test_tokenMismatch_ethWithErc20Token_reverts() public {
        // Attacker constructs a context claiming the token is victimToken (an ERC-20),
        // but sends ETH as msg.value.
        JBSplitHookContext memory context = _buildContext(address(victimToken), 1 ether);

        // Fund the terminal with ETH for the attack.
        vm.deal(terminal, 10 ether);

        // The attack should now revert with TokenMismatch.
        vm.prank(terminal);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBTokenDistributor.JBTokenDistributor_TokenMismatch.selector,
                address(victimToken),
                JBConstants.NATIVE_TOKEN,
                1 ether
            )
        );
        distributor.processSplitWith{value: 1 ether}(context);
    }

    /// @notice Proves that legitimate native ETH splits (context.token == NATIVE_TOKEN) still work.
    function test_tokenMismatch_ethWithNativeToken_succeeds() public {
        JBSplitHookContext memory context = _buildContext(JBConstants.NATIVE_TOKEN, 1 ether);

        vm.deal(terminal, 10 ether);

        vm.prank(terminal);
        distributor.processSplitWith{value: 1 ether}(context);

        // Balance should be credited under NATIVE_TOKEN.
        assertEq(
            distributor.balanceOf(hook, IERC20(JBConstants.NATIVE_TOKEN)),
            1 ether,
            "Native ETH split should credit balance under NATIVE_TOKEN"
        );
    }

    /// @notice Demonstrates the attack scenario that the fix prevents: without the fix,
    /// an attacker could steal the victim's ERC-20 balance by sending ETH with a fake token.
    function test_tokenMismatch_attackScenario_cannotStealErc20Balance() public {
        // Step 1: Victim legitimately deposits ERC-20 tokens via the terminal.
        uint256 victimAmount = 100 ether;
        victimToken.mint(terminal, victimAmount);

        JBSplitHookContext memory legitimateContext = _buildContext(address(victimToken), victimAmount);

        vm.startPrank(terminal);
        victimToken.approve(address(distributor), victimAmount);
        distributor.processSplitWith(legitimateContext);
        vm.stopPrank();

        // Verify victim's ERC-20 balance is properly recorded.
        assertEq(
            distributor.balanceOf(hook, IERC20(address(victimToken))),
            victimAmount,
            "Victim's ERC-20 balance should be credited"
        );

        // Step 2: Attacker tries to send 1 ETH but have it credited as victimToken.
        // This would allow the attacker to inflate the victimToken balance and steal from others.
        JBSplitHookContext memory attackContext = _buildContext(address(victimToken), 1 ether);

        vm.deal(terminal, 10 ether);
        vm.prank(terminal);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBTokenDistributor.JBTokenDistributor_TokenMismatch.selector,
                address(victimToken),
                JBConstants.NATIVE_TOKEN,
                1 ether
            )
        );
        distributor.processSplitWith{value: 1 ether}(attackContext);

        // Balance remains unchanged — attack blocked.
        assertEq(
            distributor.balanceOf(hook, IERC20(address(victimToken))),
            victimAmount,
            "Victim's ERC-20 balance must not change after blocked attack"
        );
    }
}

// =========================================================================
// Test: JB721Distributor token mismatch vulnerability
// =========================================================================

/// @notice Proves the ETH-to-ERC20 cross-booking vulnerability is fixed in JB721Distributor.
contract TokenMismatch721DistributorTest is Test {
    TMMockDirectory directory;
    TMVictimToken victimToken;
    JB721Distributor distributor;

    address terminal = makeAddr("terminal");
    address hook = makeAddr("nft-hook");
    uint256 projectId = 1;

    uint256 constant ROUND_DURATION = 100;
    uint256 constant VESTING_ROUNDS = 4;

    function setUp() public {
        directory = new TMMockDirectory();
        victimToken = new TMVictimToken();

        directory.setTerminal(projectId, terminal, true);

        distributor = new JB721Distributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);
    }

    /// @notice Helper to build a JBSplitHookContext.
    function _buildContext(address token, uint256 amount) internal view returns (JBSplitHookContext memory) {
        JBSplit memory split = JBSplit({
            percent: 1_000_000_000,
            projectId: 0,
            beneficiary: payable(hook),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(distributor))
        });

        return JBSplitHookContext({
            token: token, amount: amount, decimals: 18, projectId: projectId, groupId: 0, split: split
        });
    }

    /// @notice Proves the fix: sending ETH with context.token set to an ERC-20 address reverts.
    function test_tokenMismatch_721_ethWithErc20Token_reverts() public {
        JBSplitHookContext memory context = _buildContext(address(victimToken), 1 ether);

        vm.deal(terminal, 10 ether);

        vm.prank(terminal);
        vm.expectRevert(
            abi.encodeWithSelector(
                JB721Distributor.JB721Distributor_TokenMismatch.selector,
                address(victimToken),
                JBConstants.NATIVE_TOKEN,
                1 ether
            )
        );
        distributor.processSplitWith{value: 1 ether}(context);
    }

    /// @notice Proves that legitimate native ETH splits still work for JB721Distributor.
    function test_tokenMismatch_721_ethWithNativeToken_succeeds() public {
        JBSplitHookContext memory context = _buildContext(JBConstants.NATIVE_TOKEN, 1 ether);

        vm.deal(terminal, 10 ether);

        vm.prank(terminal);
        distributor.processSplitWith{value: 1 ether}(context);

        // Balance should be credited under NATIVE_TOKEN.
        assertEq(
            distributor.balanceOf(hook, IERC20(JBConstants.NATIVE_TOKEN)),
            1 ether,
            "Native ETH split should credit balance under NATIVE_TOKEN"
        );
    }

    /// @notice Full attack scenario blocked on JB721Distributor.
    function test_tokenMismatch_721_attackScenario_cannotStealErc20Balance() public {
        // Step 1: Legitimate ERC-20 deposit.
        uint256 victimAmount = 50 ether;
        victimToken.mint(terminal, victimAmount);

        JBSplitHookContext memory legitimateContext = _buildContext(address(victimToken), victimAmount);

        vm.startPrank(terminal);
        victimToken.approve(address(distributor), victimAmount);
        distributor.processSplitWith(legitimateContext);
        vm.stopPrank();

        assertEq(
            distributor.balanceOf(hook, IERC20(address(victimToken))), victimAmount, "Victim balance should be credited"
        );

        // Step 2: Attack — send ETH but claim it as victimToken.
        JBSplitHookContext memory attackContext = _buildContext(address(victimToken), 1 ether);

        vm.deal(terminal, 10 ether);
        vm.prank(terminal);
        vm.expectRevert(
            abi.encodeWithSelector(
                JB721Distributor.JB721Distributor_TokenMismatch.selector,
                address(victimToken),
                JBConstants.NATIVE_TOKEN,
                1 ether
            )
        );
        distributor.processSplitWith{value: 1 ether}(attackContext);

        // Balance unaffected.
        assertEq(
            distributor.balanceOf(hook, IERC20(address(victimToken))),
            victimAmount,
            "Balance must remain unchanged after blocked attack"
        );
    }
}
