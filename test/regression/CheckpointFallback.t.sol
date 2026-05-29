// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";
import {JB721Distributor} from "../../src/JB721Distributor.sol";

contract MockDirectory {}

contract MockRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract Mock721Store {
    function tierOfTokenId(address, uint256, bool) external pure returns (JB721Tier memory tier) {
        tier = JB721Tier({
            id: 1,
            price: 0,
            remainingSupply: 0,
            initialSupply: 0,
            votingUnits: 100 ether,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIpfsUri: bytes32(0),
            category: 0,
            discountPercent: 0,
            flags: JB721TierFlags({
                allowOwnerMint: false,
                transfersPausable: false,
                cantBeRemoved: false,
                cantIncreaseDiscountPercent: false,
                cantBuyWithCredits: false
            }),
            splitPercent: 0,
            resolvedUri: ""
        });
    }
}

contract Mock721Checkpoints {
    Mock721Hook public hook;
    mapping(address account => uint256 votes) public votesOf;
    uint256 public totalSupply;

    constructor(Mock721Hook hook_) {
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

contract Mock721Hook {
    Mock721Store public immutable STORE;
    Mock721Checkpoints public immutable CHECKPOINTS;

    mapping(uint256 tokenId => address owner) public ownerOfToken;
    mapping(uint256 tokenId => address firstOwner) public firstOwnerOfToken;
    mapping(uint256 tokenId => uint256 firstTransferBlock) public firstTransferBlockOf;
    mapping(uint256 tokenId => address transferredTo) public transferredToOf;
    mapping(uint256 tokenId => uint256 blockNumber) public mintBlockOf;

    constructor() {
        STORE = new Mock721Store();
        CHECKPOINTS = new Mock721Checkpoints(this);
    }

    function checkpoints() external view returns (Mock721Checkpoints) {
        return CHECKPOINTS;
    }

    function mint(uint256 tokenId, address owner) external {
        ownerOfToken[tokenId] = owner;
        if (mintBlockOf[tokenId] == 0) mintBlockOf[tokenId] = block.number;
    }

    function transfer(uint256 tokenId, address to) external {
        address from = ownerOf(tokenId);
        if (firstOwnerOfToken[tokenId] == address(0)) firstOwnerOfToken[tokenId] = from;
        firstTransferBlockOf[tokenId] = block.number;
        transferredToOf[tokenId] = to;
        ownerOfToken[tokenId] = to;
    }

    function ownerOf(uint256 tokenId) public view returns (address owner) {
        owner = ownerOfToken[tokenId];
        require(owner != address(0), "NOT_MINTED");
    }

    function firstOwnerOf(uint256 tokenId) public view returns (address) {
        address firstOwner = firstOwnerOfToken[tokenId];
        return firstOwner != address(0) ? firstOwner : ownerOf(tokenId);
    }

    function ownerOfAtLikeInstalledCheckpoints(uint256 tokenId, uint256 blockNumber) external view returns (address) {
        uint256 mintBlock = mintBlockOf[tokenId];
        if (mintBlock == 0 || mintBlock > blockNumber) return address(0);

        uint256 firstTransferBlock = firstTransferBlockOf[tokenId];
        if (firstTransferBlock == 0 || firstTransferBlock > blockNumber) return firstOwnerOf(tokenId);
        return transferredToOf[tokenId];
    }
}

contract CheckpointFallbackTest is Test {
    function test_lateMintedReplacementCannotConsumeSnapshotVotesBeforeRealSnapshotToken() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);

        JB721Distributor distributor = new JB721Distributor(
            IJBDirectory(address(new MockDirectory())),
            IJBController(address(0)),
            IREVLoans(address(0)),
            IREVOwner(address(0)),
            1 days,
            1,
            0
        );
        MockRewardToken reward = new MockRewardToken();
        Mock721Hook hook = new Mock721Hook();

        hook.mint(1, alice);
        hook.checkpoints().setVotes(alice, 100 ether);
        hook.checkpoints().setTotalSupply(100 ether);
        vm.roll(block.number + 1);

        reward.mint(address(this), 100 ether);
        reward.approve(address(distributor), 100 ether);
        distributor.fund(address(hook), IERC20(address(reward)), 100 ether);
        uint256 snapshotBlock = distributor.roundSnapshotBlock(0);
        vm.roll(snapshotBlock + 2);

        hook.transfer(1, bob);
        hook.mint(2, alice);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));

        uint256[] memory lateTokenIds = new uint256[](1);
        lateTokenIds[0] = 2;
        vm.warp(distributor.roundStartTimestamp(1) + 1);
        vm.roll(block.number + 1);
        vm.prank(alice);
        distributor.beginVesting(address(hook), lateTokenIds, tokens);

        uint256[] memory realSnapshotTokenIds = new uint256[](1);
        realSnapshotTokenIds[0] = 1;
        vm.prank(bob);
        distributor.beginVesting(address(hook), realSnapshotTokenIds, tokens);

        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(reward))), 0);
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(reward))), 100 ether);

        vm.warp(distributor.roundStartTimestamp(2) + 1);

        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), lateTokenIds, tokens, alice);
        vm.prank(bob);
        distributor.collectVestedRewards(address(hook), realSnapshotTokenIds, tokens, bob);

        assertEq(reward.balanceOf(alice), 0);
        assertEq(reward.balanceOf(bob), 100 ether);
    }
}
