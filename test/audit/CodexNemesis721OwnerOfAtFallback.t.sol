// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";

import {JB721Distributor} from "../../src/JB721Distributor.sol";

contract CodexNemesisRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CodexNemesisDirectory {
    function isTerminalOf(uint256, IJBTerminal) external pure returns (bool) {
        return false;
    }

    function controllerOf(uint256) external pure returns (IERC165) {
        return IERC165(address(0));
    }
}

contract CodexNemesis721Store {
    function tierOfTokenId(address, uint256, bool) external pure returns (JB721Tier memory tier) {
        tier.votingUnits = 100 ether;
    }
}

contract CodexNemesis721Checkpoints {
    CodexNemesis721Hook public hook;
    mapping(address account => uint256 votes) public votesOf;
    uint256 public totalSupply;

    function setHook(CodexNemesis721Hook hook_) external {
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
        return hook.ownerOfAtLikeInstalledCheckpoints(tokenId, blockNumber);
    }
}

contract CodexNemesis721Hook {
    CodexNemesis721Store public immutable STORE;
    CodexNemesis721Checkpoints public immutable CHECKPOINTS;

    mapping(uint256 tokenId => address owner) public ownerOf;
    mapping(uint256 tokenId => address firstOwner) public firstOwnerOfToken;
    mapping(uint256 tokenId => uint256 firstCheckpointBlock) public firstCheckpointBlockOf;
    mapping(uint256 tokenId => address checkpointOwner) public checkpointOwnerOf;
    mapping(uint256 tokenId => uint256 blockNumber) public mintBlockOf;

    constructor(CodexNemesis721Store store, CodexNemesis721Checkpoints checkpoints_) {
        STORE = store;
        CHECKPOINTS = checkpoints_;
        checkpoints_.setHook(this);
    }

    function checkpoints() external view returns (CodexNemesis721Checkpoints) {
        return CHECKPOINTS;
    }

    function firstOwnerOf(uint256 tokenId) external view returns (address) {
        address first = firstOwnerOfToken[tokenId];
        return first != address(0) ? first : ownerOf[tokenId];
    }

    function mint(address owner, uint256 tokenId) external {
        ownerOf[tokenId] = owner;
        if (mintBlockOf[tokenId] == 0) mintBlockOf[tokenId] = block.number;
    }

    function transferToken(address to, uint256 tokenId) external {
        address from = ownerOf[tokenId];
        if (firstOwnerOfToken[tokenId] == address(0)) firstOwnerOfToken[tokenId] = from;
        ownerOf[tokenId] = to;
        firstCheckpointBlockOf[tokenId] = block.number;
        checkpointOwnerOf[tokenId] = to;
    }

    function ownerOfAtLikeInstalledCheckpoints(uint256 tokenId, uint256 blockNumber) external view returns (address) {
        uint256 mintBlock = mintBlockOf[tokenId];
        if (mintBlock == 0 || mintBlock > blockNumber) return address(0);

        uint256 checkpointBlock = firstCheckpointBlockOf[tokenId];
        if (checkpointBlock == 0 || checkpointBlock > blockNumber) {
            address first = firstOwnerOfToken[tokenId];
            return first != address(0) ? first : ownerOf[tokenId];
        }
        return checkpointOwnerOf[tokenId];
    }
}

contract CodexNemesis721OwnerOfAtFallbackTest is Test {
    uint256 internal constant ROUND_DURATION = 1 days;
    uint256 internal constant VESTING_ROUNDS = 1;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function test_lateMintedReplacementCannotConsumeSnapshotVotesBeforeRealSnapshotToken() public {
        JB721Distributor distributor =
            new JB721Distributor(IJBDirectory(address(new CodexNemesisDirectory())), ROUND_DURATION, VESTING_ROUNDS);
        CodexNemesisRewardToken reward = new CodexNemesisRewardToken();
        CodexNemesis721Store store = new CodexNemesis721Store();
        CodexNemesis721Checkpoints checkpoints = new CodexNemesis721Checkpoints();
        CodexNemesis721Hook hook = new CodexNemesis721Hook(store, checkpoints);

        hook.mint(alice, 1);
        checkpoints.setVotes(alice, 100 ether);
        checkpoints.setTotalSupply(100 ether);
        vm.roll(block.number + 1);

        reward.mint(address(this), 100 ether);
        reward.approve(address(distributor), 100 ether);
        distributor.fund(address(hook), IERC20(address(reward)), 100 ether);
        uint256 snapshotBlock = distributor.roundSnapshotBlock(0);

        vm.roll(snapshotBlock + 2);
        hook.transferToken(bob, 1);
        hook.mint(alice, 2);

        uint256[] memory tokenIds = new uint256[](1);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));

        vm.warp(distributor.roundStartTimestamp(1) + 1);
        vm.roll(block.number + 1);

        tokenIds[0] = 2;
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        tokenIds[0] = 1;
        vm.prank(bob);
        distributor.beginVesting(address(hook), tokenIds, tokens);

        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(reward))), 0);
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(reward))), 100 ether);

        vm.warp(distributor.roundStartTimestamp(2) + 1);

        tokenIds[0] = 2;
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        tokenIds[0] = 1;
        vm.prank(bob);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, bob);

        assertEq(reward.balanceOf(alice), 0);
        assertEq(reward.balanceOf(bob), 100 ether);
    }
}
