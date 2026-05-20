// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JB721Distributor} from "../src/JB721Distributor.sol";
import {MockFeeOnTransferToken} from "./mock/MockFeeOnTransferToken.sol";

/// @notice Local stub directory — `fund` doesn't call into the directory but the constructor takes one.
contract _FotDirectory {
    mapping(uint256 => mapping(address => bool)) public terminals;
    mapping(uint256 => address) public controllers;

    function setTerminal(uint256 p, address t, bool ok) external { terminals[p][t] = ok; }
    function isTerminalOf(uint256 p, IJBTerminal t) external view returns (bool) { return terminals[p][address(t)]; }
    function controllerOf(uint256 p) external view returns (IERC165) { return IERC165(controllers[p]); }
}

/// @notice Pins `JBDistributor._acceptErc20FundsFrom`'s balance-delta crediting against a real fee-on-transfer
/// token implementation. Without this test the central new mechanism in the audit-hardening PR (delta-based
/// accounting) is unproven for the token class it was designed to support.
contract FeeOnTransferFundingTest is Test {
    uint256 internal constant _ROUND_DURATION = 1 days;
    uint256 internal constant _VESTING_ROUNDS = 3;

    JB721Distributor internal distributor;
    _FotDirectory internal directory;
    MockFeeOnTransferToken internal fotToken; // 1% fee
    address internal hook = address(0xBEEF);
    address internal funder = address(0xCAFE);

    function setUp() public {
        directory = new _FotDirectory();
        distributor = new JB721Distributor(IJBDirectory(address(directory)), _ROUND_DURATION, _VESTING_ROUNDS);
        fotToken = new MockFeeOnTransferToken({_feeBps: 100}); // 1%
        fotToken.mint(funder, 1_000e18);
        vm.prank(funder);
        fotToken.approve(address(distributor), type(uint256).max);
    }

    /// @notice Funding with a fee-on-transfer token credits only the actual received amount (1% less), not the
    /// caller-provided nominal `amount`.
    function test_fund_feeOnTransfer_creditsDelta() public {
        uint256 nominal = 100e18;
        uint256 expectedFee = nominal / 100; // 1%
        uint256 expectedCredit = nominal - expectedFee;

        uint256 hookBalanceBefore = distributor.balanceOf(hook, IERC20(address(fotToken)));
        uint256 actualBalanceBefore = fotToken.balanceOf(address(distributor));

        vm.prank(funder);
        distributor.fund(hook, IERC20(address(fotToken)), nominal);

        uint256 hookBalanceAfter = distributor.balanceOf(hook, IERC20(address(fotToken)));
        uint256 actualBalanceAfter = fotToken.balanceOf(address(distributor));

        assertEq(
            hookBalanceAfter - hookBalanceBefore,
            expectedCredit,
            "hook credit should equal real balance delta, not nominal amount"
        );
        assertEq(actualBalanceAfter - actualBalanceBefore, expectedCredit, "real token balance matches credited delta");
        assertEq(
            distributor.balanceOf(hook, IERC20(address(fotToken))),
            actualBalanceAfter,
            "accounted balance never exceeds actual on-chain balance"
        );
    }

    /// @notice Repeated fee-on-transfer fundings accumulate correctly — each credit is the delta of that call.
    function test_fund_feeOnTransfer_multipleRoundsAccumulate() public {
        uint256 nominal = 10e18;
        uint256 expectedPerCall = nominal - (nominal / 100);

        for (uint256 i; i < 5; ++i) {
            vm.prank(funder);
            distributor.fund(hook, IERC20(address(fotToken)), nominal);
        }

        assertEq(
            distributor.balanceOf(hook, IERC20(address(fotToken))),
            expectedPerCall * 5,
            "accumulated credit equals sum of per-call deltas"
        );
        assertEq(
            fotToken.balanceOf(address(distributor)),
            expectedPerCall * 5,
            "real token balance matches credited sum"
        );
    }

    /// @notice The reentrancy guard names the in-flight token if a callback-capable reward token reenters during the
    /// safeTransferFrom. Here we just confirm the no-callback path doesn't trigger it.
    function test_fund_feeOnTransfer_doesNotTriggerReentrancyGuard() public {
        vm.prank(funder);
        // Reverts inside the guard would surface here; the FOT path is not reentrant on its own.
        distributor.fund(hook, IERC20(address(fotToken)), 1e18);
        // If we got here, the guard didn't false-positive on a plain FOT transfer.
    }
}
