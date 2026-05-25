// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JBTokenDistributor} from "../../src/JBTokenDistributor.sol";

contract CodexNemesisZeroDirectory {
    function isTerminalOf(uint256, IJBTerminal) external pure returns (bool) {
        return false;
    }

    function controllerOf(uint256) external pure returns (IERC165) {
        return IERC165(address(0));
    }
}

contract CodexNemesisZeroRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CodexNemesisVotes {
    uint256 public totalSupply;
    mapping(address account => uint256 votes) public votesOf;

    function setVotes(address account, uint256 votes) external {
        votesOf[account] = votes;
    }

    function setTotalSupply(uint256 totalSupply_) external {
        totalSupply = totalSupply_;
    }

    function getPastVotes(address account, uint256) external view returns (uint256) {
        return votesOf[account];
    }

    function getPastTotalSupply(uint256) external view returns (uint256) {
        return totalSupply;
    }
}

contract CodexNemesisZeroAmountVestingDoSTest is Test {
    function testZeroAmountEntriesAreSkipped() public {
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        address voter = makeAddr("voter");

        JBTokenDistributor distributor =
            new JBTokenDistributor(IJBDirectory(address(new CodexNemesisZeroDirectory())), 1 days, 1, 0);
        CodexNemesisZeroRewardToken reward = new CodexNemesisZeroRewardToken();
        CodexNemesisVotes votes = new CodexNemesisVotes();

        votes.setVotes(voter, 1 ether);
        votes.setTotalSupply(1 ether);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(victim));

        for (uint256 i; i < 3; i++) {
            vm.warp(distributor.roundStartTimestamp(i) + 1);
            reward.mint(attacker, 1);
            vm.startPrank(attacker);
            reward.approve(address(distributor), 1);
            distributor.fund(address(votes), IERC20(address(reward)), 1);
            vm.stopPrank();
        }

        // Zero-amount entries are not pushed — accessing index 0 reverts.
        vm.expectRevert();
        distributor.vestingDataOf(address(votes), tokenIds[0], IERC20(address(reward)), 0);

        vm.warp(distributor.roundStartTimestamp(10) + 1);
        vm.prank(victim);
        distributor.collectVestedRewards(address(votes), tokenIds, tokens, victim);

        // latestVestedIndexOf stays at 0 (default, no entries to scan).
        assertEq(distributor.latestVestedIndexOf(address(votes), tokenIds[0], IERC20(address(reward))), 0);
        assertEq(distributor.collectableFor(address(votes), tokenIds[0], IERC20(address(reward))), 0);
    }
}
