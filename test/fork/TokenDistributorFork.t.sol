// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

// Core contracts.
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBProjects} from "@bananapus/core-v6/src/JBProjects.sol";
import {JBDirectory} from "@bananapus/core-v6/src/JBDirectory.sol";
import {JBController} from "@bananapus/core-v6/src/JBController.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBTerminalStore} from "@bananapus/core-v6/src/JBTerminalStore.sol";
import {JBRulesets} from "@bananapus/core-v6/src/JBRulesets.sol";
import {JBTokens} from "@bananapus/core-v6/src/JBTokens.sol";
import {JBPrices} from "@bananapus/core-v6/src/JBPrices.sol";
import {JBSplits} from "@bananapus/core-v6/src/JBSplits.sol";
import {JBFundAccessLimits} from "@bananapus/core-v6/src/JBFundAccessLimits.sol";
import {JBFeelessAddresses} from "@bananapus/core-v6/src/JBFeelessAddresses.sol";
import {JBERC20} from "@bananapus/core-v6/src/JBERC20.sol";

// Core interfaces.
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBRulesetApprovalHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetApprovalHook.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";

// Core structs.
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "@bananapus/core-v6/src/structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBSplitGroup} from "@bananapus/core-v6/src/structs/JBSplitGroup.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBFundAccessLimitGroup} from "@bananapus/core-v6/src/structs/JBFundAccessLimitGroup.sol";
import {JBCurrencyAmount} from "@bananapus/core-v6/src/structs/JBCurrencyAmount.sol";

// Core libraries.
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";

// OZ.
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

// Permit2.
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

// Distributor.
import {JBTokenDistributor} from "../../src/JBTokenDistributor.sol";

/// @notice Fork tests for JBTokenDistributor against real JB core on mainnet fork.
/// @dev Deploys full JB core, launches a project with JBERC20, and tests the complete
/// fund -> vest -> collect lifecycle using real IVotes checkpoints.
contract TokenDistributorForkTest is Test {
    // -- JB core --
    JBPermissions jbPermissions;
    JBProjects jbProjects;
    JBDirectory jbDirectory;
    JBRulesets jbRulesets;
    JBTokens jbTokens;
    JBPrices jbPrices;
    JBSplits jbSplits;
    JBFundAccessLimits jbFundAccessLimits;
    JBFeelessAddresses jbFeelessAddresses;
    JBController jbController;
    JBTerminalStore jbTerminalStore;
    JBMultiTerminal jbMultiTerminal;

    // -- Distributor --
    JBTokenDistributor distributor;

    // -- Actors --
    address multisig;
    address alice;
    address bob;
    address carol;

    // -- Project state --
    uint256 feeProjectId;
    uint256 projectId;
    IJBToken projectToken;

    // -- Config --
    uint256 constant ROUND_DURATION = 1 weeks;
    uint256 constant VESTING_ROUNDS = 4;

    // Mainnet Permit2.
    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    function setUp() public {
        vm.createSelectFork("ethereum", 24_981_600);

        // Create labeled addresses and ensure they're clean EOAs (no mainnet code).
        multisig = makeAddr("test_distributor_multisig");
        alice = makeAddr("test_distributor_alice");
        bob = makeAddr("test_distributor_bob");
        carol = makeAddr("test_distributor_carol");
        vm.etch(multisig, "");
        vm.etch(alice, "");
        vm.etch(bob, "");
        vm.etch(carol, "");

        _deployJBCore();
        _deployDistributor();

        // Launch fee project (must be project #1).
        feeProjectId = _launchFeeProject();
        assertEq(feeProjectId, 1, "fee project must be #1");

        // Launch test project (no splits initially — will add after token deploy).
        projectId = _launchProject();

        // Deploy JBERC20 for the project.
        vm.prank(multisig);
        projectToken = jbController.deployERC20For(projectId, "Test Token", "TST", bytes32(0));

        // Pay ETH into the project to build surplus (mints JBERC20 to payers).
        _payProject(alice, 70 ether);
        _payProject(bob, 30 ether);

        // Delegates must delegate to themselves for IVotes checkpoints.
        vm.prank(alice);
        JBERC20(address(projectToken)).delegate(alice);

        vm.prank(bob);
        JBERC20(address(projectToken)).delegate(bob);

        // Advance a block so getPastVotes works.
        vm.roll(block.number + 1);
    }

    // ======================================================================
    //                              TESTS
    // ======================================================================

    /// @notice Direct funding with real JBERC20 delegation: fund -> vest -> full collect.
    function test_fork_directFund_vestCollect() public {
        address hook = address(projectToken);

        // Fund the distributor directly with ETH.
        distributor.fund{value: 10 ether}(hook, IERC20(JBConstants.NATIVE_TOKEN), 10 ether);

        // Advance to round 1.
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = _tokenId(alice);
        tokenIds[1] = _tokenId(bob);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(JBConstants.NATIVE_TOKEN);

        distributor.beginVesting(hook, tokenIds, tokens);

        uint256 aliceClaimed = distributor.claimedFor(hook, _tokenId(alice), IERC20(JBConstants.NATIVE_TOKEN));
        uint256 bobClaimed = distributor.claimedFor(hook, _tokenId(bob), IERC20(JBConstants.NATIVE_TOKEN));

        // Total = 10 ETH. Allocation proportional to voting power.
        assertEq(aliceClaimed + bobClaimed, 10 ether, "Sum should equal funded amount");
        assertGt(aliceClaimed, bobClaimed, "Alice should get more (70% vs 30%)");

        // Full vest + collect.
        _advanceToRound(1 + VESTING_ROUNDS);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        distributor.collectVestedRewards(hook, _singleTokenId(alice), tokens, alice);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        distributor.collectVestedRewards(hook, _singleTokenId(bob), tokens, bob);

        assertEq(alice.balance - aliceBefore, aliceClaimed, "Alice ETH collected");
        assertEq(bob.balance - bobBefore, bobClaimed, "Bob ETH collected");
    }

    /// @notice Undelegated tokens don't earn rewards — funds not allocated to undelegated holders.
    function test_fork_undelegatedTokens_noRewards() public {
        address hook = address(projectToken);

        // Carol pays but does NOT delegate.
        _payProject(carol, 50 ether);
        vm.roll(block.number + 1);

        distributor.fund{value: 10 ether}(hook, IERC20(JBConstants.NATIVE_TOKEN), 10 ether);
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = _tokenId(alice);
        tokenIds[1] = _tokenId(bob);
        tokenIds[2] = _tokenId(carol);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(JBConstants.NATIVE_TOKEN);

        distributor.beginVesting(hook, tokenIds, tokens);

        // Carol should have 0 claimed (no delegation).
        uint256 carolClaimed = distributor.claimedFor(hook, _tokenId(carol), IERC20(JBConstants.NATIVE_TOKEN));
        assertEq(carolClaimed, 0, "Carol should have 0 (not delegated)");

        // Undelegated portion (Carol's supply) dilutes total supply, reducing Alice/Bob allocations.
        uint256 totalVesting = distributor.totalVestingAmountOf(hook, IERC20(JBConstants.NATIVE_TOKEN));
        assertLt(totalVesting, 10 ether, "Not all funds distributed (undelegated supply dilutes)");
    }

    /// @notice Partial vesting — collect mid-way through vesting period.
    function test_fork_partialVesting_linearUnlock() public {
        address hook = address(projectToken);
        distributor.fund{value: 10 ether}(hook, IERC20(JBConstants.NATIVE_TOKEN), 10 ether);
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(alice);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(JBConstants.NATIVE_TOKEN);

        distributor.beginVesting(hook, tokenIds, tokens);

        uint256 aliceClaimed = distributor.claimedFor(hook, _tokenId(alice), IERC20(JBConstants.NATIVE_TOKEN));
        assertGt(aliceClaimed, 0, "Alice claimed something");

        // After 2 of 4 vesting rounds, 50% collectable.
        _advanceToRound(3);
        uint256 collectable = distributor.collectableFor(hook, _tokenId(alice), IERC20(JBConstants.NATIVE_TOKEN));
        assertApproxEqAbs(collectable, aliceClaimed / 2, 1, "~50% collectable at midpoint");

        // Collect partial.
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        distributor.collectVestedRewards(hook, _singleTokenId(alice), tokens, alice);
        assertApproxEqAbs(alice.balance - aliceBefore, aliceClaimed / 2, 1, "Alice gets ~50%");
    }

    /// @notice Multi-round: fund in round 1, fund more in round 3, collect all.
    function test_fork_multiRound_carryOverAndNewFunding() public {
        address hook = address(projectToken);

        // Fund round 1.
        distributor.fund{value: 5 ether}(hook, IERC20(JBConstants.NATIVE_TOKEN), 5 ether);
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = _tokenId(alice);
        tokenIds[1] = _tokenId(bob);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(JBConstants.NATIVE_TOKEN);

        distributor.beginVesting(hook, tokenIds, tokens);

        uint256 round1AliceClaimed = distributor.claimedFor(hook, _tokenId(alice), IERC20(JBConstants.NATIVE_TOKEN));

        // Fund more in round 3.
        _advanceToRound(3);
        distributor.fund{value: 5 ether}(hook, IERC20(JBConstants.NATIVE_TOKEN), 5 ether);

        // Begin vesting round 3 funds.
        _advanceToRound(4);
        distributor.beginVesting(hook, tokenIds, tokens);

        // Advance past both vesting periods.
        _advanceToRound(1 + VESTING_ROUNDS + VESTING_ROUNDS);

        // Collect all.
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        distributor.collectVestedRewards(hook, _singleTokenId(alice), tokens, alice);
        uint256 aliceCollected = alice.balance - aliceBefore;

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        distributor.collectVestedRewards(hook, _singleTokenId(bob), tokens, bob);
        uint256 bobCollected = bob.balance - bobBefore;

        // Conservation: alice + bob should account for all distributed funds.
        uint256 totalCollected = aliceCollected + bobCollected;
        assertGt(totalCollected, 0, "Non-zero collection");
        assertLe(totalCollected, 10 ether, "Cannot collect more than funded");
        // Alice got rewards from both rounds.
        assertGt(aliceCollected, round1AliceClaimed, "Alice got more than just round 1");
    }

    /// @notice Split integration: queue a ruleset with distributor split, trigger payout.
    function test_fork_payoutSplit_fundsDistributor() public {
        address hook = address(projectToken);

        // Queue a new ruleset with splits configured.
        _queueRulesetWithDistributorSplit(hook);

        // Pay more ETH into the project to build payout balance.
        _payProject(alice, 20 ether);
        vm.roll(block.number + 1);

        // Trigger payouts.
        vm.prank(multisig);
        jbMultiTerminal.sendPayoutsOf({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: 10 ether,
            currency: uint256(uint160(JBConstants.NATIVE_TOKEN)),
            minTokensPaidOut: 0
        });

        // Verify distributor received funds.
        uint256 distributorBalance = distributor.balanceOf(hook, IERC20(JBConstants.NATIVE_TOKEN));
        assertGt(distributorBalance, 0, "Distributor should have received ETH from payout");

        // Vest and collect.
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = _tokenId(alice);
        tokenIds[1] = _tokenId(bob);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(JBConstants.NATIVE_TOKEN);

        distributor.beginVesting(hook, tokenIds, tokens);

        uint256 aliceClaimed = distributor.claimedFor(hook, _tokenId(alice), IERC20(JBConstants.NATIVE_TOKEN));
        assertGt(aliceClaimed, 0, "Alice claimed from payout-funded distributor");
    }

    /// @notice Poke records snapshot blocks correctly and is idempotent.
    function test_fork_poke_snapshotConsistency() public {
        _advanceToRound(1);

        uint256 blockBefore = block.number;
        distributor.poke();

        uint256 snapshotBlock = distributor.roundSnapshotBlock(1);
        assertEq(snapshotBlock, blockBefore - 1, "Snapshot = block.number - 1");

        // Next round should also be eagerly locked.
        uint256 nextSnapshot = distributor.roundSnapshotBlock(2);
        assertEq(nextSnapshot, blockBefore - 1, "Eager lock round+1");

        // Idempotent.
        vm.roll(block.number + 10);
        distributor.poke();
        assertEq(distributor.roundSnapshotBlock(1), snapshotBlock, "Poke idempotent");
    }

    /// @notice Cannot collect another staker's rewards.
    function test_fork_cannotCollectOthersRewards() public {
        address hook = address(projectToken);
        distributor.fund{value: 5 ether}(hook, IERC20(JBConstants.NATIVE_TOKEN), 5 ether);
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId(alice);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(JBConstants.NATIVE_TOKEN);
        distributor.beginVesting(hook, tokenIds, tokens);

        _advanceToRound(1 + VESTING_ROUNDS);

        // Bob tries to collect Alice's rewards.
        vm.prank(bob);
        vm.expectRevert();
        distributor.collectVestedRewards(hook, _singleTokenId(alice), tokens, bob);
    }

    /// @notice Auto-vest: calling collectVestedRewards without explicit beginVesting still works.
    function test_fork_autoVest_collectWithoutExplicitBeginVesting() public {
        address hook = address(projectToken);
        distributor.fund{value: 10 ether}(hook, IERC20(JBConstants.NATIVE_TOKEN), 10 ether);

        // Skip beginVesting — go straight to collect.
        _advanceToRound(1 + VESTING_ROUNDS);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(JBConstants.NATIVE_TOKEN);

        vm.prank(alice);
        distributor.collectVestedRewards(hook, _singleTokenId(alice), tokens, alice);

        // Auto-vest should have kicked in — Alice got some rewards.
        uint256 claimed = distributor.claimedFor(hook, _tokenId(alice), IERC20(JBConstants.NATIVE_TOKEN));
        assertGt(claimed, 0, "Auto-vest should have created a vesting entry");
    }

    /// @notice Invariant: totalVestingAmount never exceeds balance.
    function test_fork_conservationInvariant() public {
        address hook = address(projectToken);
        distributor.fund{value: 10 ether}(hook, IERC20(JBConstants.NATIVE_TOKEN), 10 ether);
        _advanceToRound(1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = _tokenId(alice);
        tokenIds[1] = _tokenId(bob);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(JBConstants.NATIVE_TOKEN);

        distributor.beginVesting(hook, tokenIds, tokens);

        uint256 totalVesting = distributor.totalVestingAmountOf(hook, IERC20(JBConstants.NATIVE_TOKEN));
        uint256 balance = distributor.balanceOf(hook, IERC20(JBConstants.NATIVE_TOKEN));
        assertLe(totalVesting, balance, "Vesting <= balance (conservation)");

        // Partially collect.
        _advanceToRound(3);
        vm.prank(alice);
        distributor.collectVestedRewards(hook, _singleTokenId(alice), tokens, alice);

        totalVesting = distributor.totalVestingAmountOf(hook, IERC20(JBConstants.NATIVE_TOKEN));
        balance = distributor.balanceOf(hook, IERC20(JBConstants.NATIVE_TOKEN));
        assertLe(totalVesting, balance, "Vesting <= balance after partial collect");
    }

    // ======================================================================
    //                            HELPERS
    // ======================================================================

    function _tokenId(address staker) internal pure returns (uint256) {
        return uint256(uint160(staker));
    }

    function _singleTokenId(address staker) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = _tokenId(staker);
    }

    function _advanceToRound(uint256 round) internal {
        uint256 target = distributor.roundStartTimestamp(round) + 1;
        // Test helper only moves time forward to the requested round boundary.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < target) vm.warp(target);
        vm.roll(block.number + 1);
    }

    function _payProject(address payer, uint256 amount) internal {
        vm.deal(payer, amount);
        vm.prank(payer);
        jbMultiTerminal.pay{value: amount}({
            projectId: projectId,
            token: JBConstants.NATIVE_TOKEN,
            amount: amount,
            beneficiary: payer,
            minReturnedTokens: 0,
            memo: "",
            metadata: ""
        });
    }

    // ======================================================================
    //                          DEPLOYMENT
    // ======================================================================

    function _deployJBCore() internal {
        jbPermissions = new JBPermissions(address(0));
        jbProjects = new JBProjects(multisig, address(0), address(0));
        jbDirectory = new JBDirectory(jbPermissions, jbProjects, multisig);

        JBERC20 jbErc20 = new JBERC20(jbPermissions, jbProjects);
        jbTokens = new JBTokens(jbDirectory, jbErc20);

        jbRulesets = new JBRulesets(jbDirectory);
        jbPrices = new JBPrices(jbDirectory, jbPermissions, jbProjects, multisig, address(0));

        jbSplits = new JBSplits(jbDirectory);
        jbFundAccessLimits = new JBFundAccessLimits(jbDirectory);
        jbFeelessAddresses = new JBFeelessAddresses(multisig);

        jbController = new JBController(
            jbDirectory,
            jbFundAccessLimits,
            jbPermissions,
            jbPrices,
            jbProjects,
            jbRulesets,
            jbSplits,
            jbTokens,
            address(0),
            address(0)
        );

        vm.prank(multisig);
        jbDirectory.setIsAllowedToSetFirstController(address(jbController), true);

        jbTerminalStore = new JBTerminalStore(jbDirectory, jbPrices, jbRulesets);

        jbMultiTerminal = new JBMultiTerminal(
            jbFeelessAddresses, jbPermissions, jbProjects, jbSplits, jbTerminalStore, jbTokens, PERMIT2, address(0)
        );
    }

    function _deployDistributor() internal {
        distributor = new JBTokenDistributor(IJBDirectory(address(jbDirectory)), ROUND_DURATION, VESTING_ROUNDS);

        // Mark the distributor as feeless so payouts to it aren't reduced by the 2.5% fee.
        vm.prank(multisig);
        jbFeelessAddresses.setFeelessAddress(address(distributor), true);
    }

    function _launchFeeProject() internal returns (uint256) {
        JBRulesetConfig[] memory rulesets = new JBRulesetConfig[](1);
        rulesets[0] = _basicRulesetConfig(new JBSplitGroup[](0), new JBFundAccessLimitGroup[](0));

        JBTerminalConfig[] memory terminals = new JBTerminalConfig[](1);
        terminals[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: _ethContext()});

        vm.prank(multisig);
        return jbController.launchProjectFor(multisig, "", rulesets, terminals, "");
    }

    function _launchProject() internal returns (uint256) {
        // Payout limit: allows sending 10 ETH in payouts.
        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({amount: 100 ether, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

        JBFundAccessLimitGroup[] memory fundLimits = new JBFundAccessLimitGroup[](1);
        fundLimits[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        JBRulesetConfig[] memory rulesets = new JBRulesetConfig[](1);
        rulesets[0] = _basicRulesetConfig(new JBSplitGroup[](0), fundLimits);

        JBTerminalConfig[] memory terminals = new JBTerminalConfig[](1);
        terminals[0] = JBTerminalConfig({terminal: jbMultiTerminal, accountingContextsToAccept: _ethContext()});

        vm.prank(multisig);
        return jbController.launchProjectFor(multisig, "", rulesets, terminals, "");
    }

    function _queueRulesetWithDistributorSplit(address hook) internal {
        JBSplit[] memory splits = new JBSplit[](1);
        splits[0] = JBSplit({
            percent: 1_000_000_000,
            projectId: 0,
            beneficiary: payable(hook), // The IVotes token address.
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(distributor))
        });

        JBSplitGroup[] memory splitGroups = new JBSplitGroup[](1);
        splitGroups[0] = JBSplitGroup({groupId: uint256(uint160(JBConstants.NATIVE_TOKEN)), splits: splits});

        JBCurrencyAmount[] memory payoutLimits = new JBCurrencyAmount[](1);
        payoutLimits[0] = JBCurrencyAmount({amount: 100 ether, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))});

        JBFundAccessLimitGroup[] memory fundLimits = new JBFundAccessLimitGroup[](1);
        fundLimits[0] = JBFundAccessLimitGroup({
            terminal: address(jbMultiTerminal),
            token: JBConstants.NATIVE_TOKEN,
            payoutLimits: payoutLimits,
            surplusAllowances: new JBCurrencyAmount[](0)
        });

        JBRulesetConfig[] memory rulesets = new JBRulesetConfig[](1);
        rulesets[0] = _basicRulesetConfig(splitGroups, fundLimits);

        vm.prank(multisig);
        jbController.queueRulesetsOf(projectId, rulesets, "");
    }

    function _basicRulesetConfig(
        JBSplitGroup[] memory splitGroups,
        JBFundAccessLimitGroup[] memory fundLimits
    )
        internal
        pure
        returns (JBRulesetConfig memory)
    {
        JBRulesetMetadata memory metadata = JBRulesetMetadata({
            reservedPercent: 0,
            cashOutTaxRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowSetCustomToken: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowSetController: false,
            allowAddAccountingContext: false,
            allowAddPriceFeed: false,
            ownerMustSendPayouts: false,
            holdFees: false,
            useTotalSurplusForCashOuts: false,
            useDataHookForPay: false,
            useDataHookForCashOut: false,
            dataHook: address(0),
            metadata: 0
        });

        return JBRulesetConfig({
            mustStartAtOrAfter: 0,
            duration: 0,
            weight: 1_000_000e18,
            weightCutPercent: 0,
            approvalHook: IJBRulesetApprovalHook(address(0)),
            metadata: metadata,
            splitGroups: splitGroups,
            fundAccessLimitGroups: fundLimits
        });
    }

    function _ethContext() internal pure returns (JBAccountingContext[] memory contexts) {
        contexts = new JBAccountingContext[](1);
        contexts[0] = JBAccountingContext({
            token: JBConstants.NATIVE_TOKEN, decimals: 18, currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });
    }
}
