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

contract CodexNemesisDirectory {
    function isTerminalOf(uint256, IJBTerminal) external pure returns (bool) {
        return false;
    }

    function controllerOf(uint256) external pure returns (IERC165) {
        return IERC165(address(0));
    }
}

contract CodexNemesisRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CodexNemesis721Store {
    function tierOfTokenId(address, uint256, bool) external pure returns (JB721Tier memory tier) {
        tier.votingUnits = 100;
    }
}

contract CodexNemesis721Checkpoints {
    address public hook;
    address public snapshotOwner;

    function setHook(address hook_) external {
        hook = hook_;
    }

    function setSnapshotOwner(address owner) external {
        snapshotOwner = owner;
    }

    function getPastVotes(address account, uint256) external view returns (uint256) {
        return account == snapshotOwner ? 100 : 0;
    }

    function getPastTotalSupply(uint256) external pure returns (uint256) {
        return 100;
    }

    function ownerOfAt(uint256 tokenId, uint256 blockNumber) external view returns (address) {
        return CodexNemesis721Hook(hook).ownerOfAt(tokenId, blockNumber);
    }
}

contract CodexNemesis721Hook {
    CodexNemesis721Store public immutable STORE;
    CodexNemesis721Checkpoints public immutable CHECKPOINTS;

    mapping(uint256 tokenId => address owner) public owners;
    mapping(uint256 tokenId => address firstOwner) public firstOwnerOfToken;
    mapping(uint256 tokenId => uint256 firstTransferBlock) public firstTransferBlockOf;
    mapping(uint256 tokenId => uint256 blockNumber) public mintBlockOf;

    constructor(CodexNemesis721Store store, CodexNemesis721Checkpoints checkpoints_) {
        STORE = store;
        CHECKPOINTS = checkpoints_;
    }

    function checkpoints() external view returns (CodexNemesis721Checkpoints) {
        return CHECKPOINTS;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = owners[tokenId];
        require(owner != address(0), "NO_OWNER");
        return owner;
    }

    function ownerOfAt(uint256 tokenId, uint256 blockNumber) external view returns (address) {
        uint256 mintBlock = mintBlockOf[tokenId];
        if (mintBlock == 0 || mintBlock > blockNumber) return address(0);

        uint256 firstTransferBlock = firstTransferBlockOf[tokenId];
        if (firstTransferBlock != 0 && blockNumber < firstTransferBlock) return firstOwnerOfToken[tokenId];

        // Matches JB721Checkpoints' pre-first-transfer fallback: a token minted after
        // the queried block but not yet transferred resolves to its current owner.
        return owners[tokenId];
    }

    function mint(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
        if (mintBlockOf[tokenId] == 0) mintBlockOf[tokenId] = block.number;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(owners[tokenId] == from, "WRONG_FROM");
        if (firstOwnerOfToken[tokenId] == address(0)) firstOwnerOfToken[tokenId] = from;
        firstTransferBlockOf[tokenId] = block.number;
        owners[tokenId] = to;
    }
}

contract CodexNemesisPostSnapshotMintTheftTest is Test {
    function testPostSnapshotMintCannotStealRewardsFromTransferredSnapshotNft() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        CodexNemesisDirectory directory = new CodexNemesisDirectory();
        JB721Distributor distributor = new JB721Distributor(IJBDirectory(address(directory)), 1 days, 1);
        CodexNemesisRewardToken reward = new CodexNemesisRewardToken();
        CodexNemesis721Store store = new CodexNemesis721Store();
        CodexNemesis721Checkpoints checkpoints = new CodexNemesis721Checkpoints();
        CodexNemesis721Hook hook = new CodexNemesis721Hook(store, checkpoints);
        checkpoints.setHook(address(hook));

        hook.mint(1, alice);
        checkpoints.setSnapshotOwner(alice);
        vm.roll(block.number + 1);

        reward.mint(address(this), 100 ether);
        reward.approve(address(distributor), 100 ether);
        distributor.fund(address(hook), IERC20(address(reward)), 100 ether);
        uint256 snapshotBlock = distributor.roundSnapshotBlock(0);

        vm.roll(block.number + 10);
        assertGt(block.number, snapshotBlock);
        hook.transferFrom(alice, bob, 1);
        hook.mint(2, alice);

        uint256[] memory tokenIds = new uint256[](1);
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));

        vm.warp(distributor.roundStartTimestamp(1) + 1);
        vm.roll(block.number + 1);

        tokenIds[0] = 2;
        vm.prank(alice);
        distributor.beginVesting(address(hook), tokenIds, tokens);
        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(reward))), 0);

        tokenIds[0] = 1;
        vm.prank(bob);
        distributor.beginVesting(address(hook), tokenIds, tokens);
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
