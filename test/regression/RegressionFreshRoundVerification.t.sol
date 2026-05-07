// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JB721Distributor} from "../../src/JB721Distributor.sol";
import {JBTokenDistributor} from "../../src/JBTokenDistributor.sol";

contract RegressionFreshRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RegressionFreshDirectory {
    function isTerminalOf(uint256, IJBTerminal) external pure returns (bool) {
        return false;
    }

    function controllerOf(uint256) external pure returns (IERC165) {
        return IERC165(address(0));
    }
}

contract RegressionFreshVotes {
    mapping(address account => uint256 votes) public votesOf;
    uint256 public totalSupply;

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

contract RegressionFresh721Store {
    function tierOfTokenId(address, uint256, bool) external pure returns (JB721Tier memory tier) {
        tier.votingUnits = 100;
        tier.initialSupply = 100;
    }

    function mintBlockOf(address, uint256 tokenId) external pure returns (uint256) {
        return tokenId == 1 ? 1 : 1_000_000;
    }
}

contract RegressionFresh721Checkpoints {
    mapping(address account => uint256 votes) public votesOf;
    uint256 public totalSupply;
    address public hook;

    function setHook(address hook_) external {
        hook = hook_;
    }

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

    function ownerOfAt(uint256 tokenId, uint256 blockNumber) external view returns (address) {
        return RegressionFresh721Hook(hook).ownerOfAt(tokenId, blockNumber);
    }
}

contract RegressionFresh721Hook {
    RegressionFresh721Store public immutable STORE;
    RegressionFresh721Checkpoints public immutable CHECKPOINTS;
    mapping(uint256 tokenId => address owner) public owners;

    constructor(RegressionFresh721Store store, RegressionFresh721Checkpoints checkpoints) {
        STORE = store;
        CHECKPOINTS = checkpoints;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = owners[tokenId];
        require(owner != address(0), "NO_OWNER");
        return owner;
    }

    function ownerOfAt(uint256 tokenId, uint256 blockNumber) external view returns (address) {
        uint256 mintBlock = STORE.mintBlockOf(address(this), tokenId);
        if (mintBlock != 0 && mintBlock > blockNumber) return address(0);
        return owners[tokenId];
    }

    function setOwner(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
    }
}

contract RegressionFreshRoundVerificationTest is Test {
    function test_postSnapshot721TokenCannotClaimUsingOwnersEarlierVotes() public {
        address alice = makeAddr("alice");
        RegressionFreshDirectory directory = new RegressionFreshDirectory();
        JB721Distributor distributor = new JB721Distributor(IJBDirectory(address(directory)), 1 days, 1);
        RegressionFreshRewardToken reward = new RegressionFreshRewardToken();
        RegressionFresh721Store store = new RegressionFresh721Store();
        RegressionFresh721Checkpoints checkpoints = new RegressionFresh721Checkpoints();
        RegressionFresh721Hook hook = new RegressionFresh721Hook(store, checkpoints);
        checkpoints.setHook(address(hook));

        reward.mint(address(this), 100 ether);
        reward.approve(address(distributor), 100 ether);
        distributor.fund(address(hook), IERC20(address(reward)), 100 ether);

        hook.setOwner(1, alice);
        checkpoints.setVotes(alice, 100);
        checkpoints.setTotalSupply(100);
        distributor.poke();
        uint256 snapshotBlock = distributor.roundSnapshotBlock(0);

        hook.setOwner(1, address(0));
        hook.setOwner(2, alice);
        assertGt(store.mintBlockOf(address(hook), 2), snapshotBlock);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 2;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));

        distributor.beginVesting(address(hook), tokenIds, tokens);
        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(reward))), 0);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);
        assertEq(reward.balanceOf(alice), 0);
    }

    function test_zeroVestingRoundsMakesRewardsImmediatelyCollectable() public {
        address alice = makeAddr("alice");
        RegressionFreshDirectory directory = new RegressionFreshDirectory();
        JBTokenDistributor distributor = new JBTokenDistributor(IJBDirectory(address(directory)), 1 days, 0);
        RegressionFreshRewardToken reward = new RegressionFreshRewardToken();
        RegressionFreshVotes votes = new RegressionFreshVotes();

        votes.setVotes(alice, 1 ether);
        votes.setTotalSupply(1 ether);
        reward.mint(address(this), 100 ether);
        reward.approve(address(distributor), 100 ether);
        distributor.fund(address(votes), IERC20(address(reward)), 100 ether);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(alice));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));

        distributor.beginVesting(address(votes), tokenIds, tokens);
        vm.prank(alice);
        distributor.collectVestedRewards(address(votes), tokenIds, tokens, alice);

        assertEq(reward.balanceOf(alice), 100 ether);
    }
}
