// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";

import {JBDistributor} from "../src/JBDistributor.sol";
import {JBTokenDistributor} from "../src/JBTokenDistributor.sol";

contract ForwardingDirectory {
    mapping(uint256 projectId => mapping(address terminal => bool)) public terminals;

    function setTerminal(uint256 projectId, address terminal, bool isTerminal) external {
        terminals[projectId][terminal] = isTerminal;
    }

    function isTerminalOf(uint256 projectId, IJBTerminal terminal) external view returns (bool) {
        return terminals[projectId][address(terminal)];
    }

    function controllerOf(uint256) external pure returns (address) {
        return address(0);
    }
}

contract ForwardingRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ForwardingVotesToken is ERC20, ERC20Votes {
    constructor() ERC20("Stake", "STK") EIP712("Stake", "1") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function getPastTotalActiveVotes(uint256 blockNumber) external view returns (uint256 activeVotes) {
        activeVotes = getPastTotalSupply(blockNumber);
    }

    function getTotalActiveVotes() external view returns (uint256 activeVotes) {
        activeVotes = totalSupply();
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}

/// @notice A sponsor relays holder actions through the trusted forwarder, which appends the signer to the calldata.
contract ERC2771ForwardingTest is Test {
    ForwardingDirectory internal directory;
    ForwardingRewardToken internal rewardToken;
    ForwardingVotesToken internal votesToken;
    JBTokenDistributor internal distributor;

    address internal forwarder = makeAddr("forwarder");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant ROUND_DURATION = 100;
    uint256 internal constant VESTING_ROUNDS = 1;
    uint256 internal constant REWARD = 1000;

    function setUp() public {
        directory = new ForwardingDirectory();
        rewardToken = new ForwardingRewardToken();
        votesToken = new ForwardingVotesToken();
        directory.setTerminal(PROJECT_ID, address(this), true);

        distributor = new JBTokenDistributor({
            directory: IJBDirectory(address(directory)),
            controller: IJBController(address(0)),
            revLoans: IREVLoans(address(0)),
            revOwner: IREVOwner(address(0)),
            initialRoundDuration: ROUND_DURATION,
            initialVestingRounds: VESTING_ROUNDS,
            initialClaimDuration: 0,
            trustedForwarder: forwarder
        });

        votesToken.mint(alice, 1000 ether);
        vm.prank(alice);
        votesToken.delegate(alice);
        vm.roll(block.number + 1);

        rewardToken.mint(address(this), REWARD);
        rewardToken.approve(address(distributor), REWARD);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), REWARD);
        _advanceToRound(1);
    }

    function test_trustsOnlyTheConfiguredForwarder() public view {
        assertEq(distributor.trustedForwarder(), forwarder);
        assertTrue(distributor.isTrustedForwarder(forwarder));
        assertFalse(distributor.isTrustedForwarder(bob));
    }

    function test_forwardedVestingAndCollectionActAsTheSigner() public {
        (uint256[] memory tokenIds, IERC20[] memory tokens) = _aliceClaim();

        _relay({
            caller: forwarder,
            data: abi.encodeCall(JBDistributor.beginVesting, (address(votesToken), tokenIds, tokens)),
            signer: alice
        });
        _advanceToRound(1 + VESTING_ROUNDS);
        _relay({
            caller: forwarder,
            data: abi.encodeCall(JBDistributor.collectVestedRewards, (address(votesToken), tokenIds, tokens, alice)),
            signer: alice
        });

        assertEq(rewardToken.balanceOf(alice), REWARD, "the signer's rewards reached the signer");
        assertEq(rewardToken.balanceOf(forwarder), 0, "the forwarder gained nothing");
    }

    function test_aSuffixFromAnyoneElseDoesNotSpoofTheSigner() public {
        (uint256[] memory tokenIds, IERC20[] memory tokens) = _aliceClaim();
        // Anyone may start vesting; collection is the step gated on the holder.
        distributor.beginVesting(address(votesToken), tokenIds, tokens);
        _advanceToRound(1 + VESTING_ROUNDS);
        bytes memory data =
            abi.encodeCall(JBDistributor.collectVestedRewards, (address(votesToken), tokenIds, tokens, bob));

        vm.prank(bob);
        (bool success, bytes memory reason) = address(distributor).call(abi.encodePacked(data, alice));

        assertFalse(success, "an untrusted caller cannot claim as the appended address");
        assertEq(
            reason,
            abi.encodeWithSelector(JBDistributor.JBDistributor_NoAccess.selector, address(votesToken), tokenIds[0], bob)
        );
    }

    function test_forwardedFundingPullsFromTheSigner() public {
        rewardToken.mint(bob, 50);
        vm.prank(bob);
        rewardToken.approve(address(distributor), 50);

        _relay({
            caller: forwarder,
            data: abi.encodeCall(JBDistributor.fund, (address(votesToken), IERC20(address(rewardToken)), 50)),
            signer: bob
        });

        assertEq(rewardToken.balanceOf(bob), 0, "the signer funded the round");
        assertEq(rewardToken.balanceOf(address(distributor)), REWARD + 50);
    }

    function test_splitProcessingNeverTrustsTheForwarderSuffix() public {
        JBSplitHookContext memory context;
        context.projectId = PROJECT_ID;
        context.split = JBSplit({
            percent: 0,
            projectId: 0,
            beneficiary: payable(address(votesToken)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(distributor))
        });
        bytes memory data = abi.encodeCall(JBTokenDistributor.processSplitWith, (context));

        // The appended address is a registered terminal, but only a direct terminal call may deliver a split.
        vm.prank(forwarder);
        (bool success, bytes memory reason) = address(distributor).call(abi.encodePacked(data, address(this)));

        assertFalse(success);
        assertEq(
            reason,
            abi.encodeWithSelector(JBTokenDistributor.JBTokenDistributor_Unauthorized.selector, PROJECT_ID, forwarder)
        );
    }

    function _aliceClaim() internal view returns (uint256[] memory tokenIds, IERC20[] memory tokens) {
        tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(alice));
        tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));
    }

    function _advanceToRound(uint256 round) internal {
        vm.warp(distributor.roundStartTimestamp(round) + 1);
        vm.roll(block.number + 1);
    }

    function _relay(address caller, bytes memory data, address signer) internal {
        vm.prank(caller);
        (bool success, bytes memory reason) = address(distributor).call(abi.encodePacked(data, signer));
        if (!success) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}
