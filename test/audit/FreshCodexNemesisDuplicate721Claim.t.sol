// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JB721Distributor} from "../../src/JB721Distributor.sol";

contract FreshNemesisDirectory {
    function isTerminalOf(uint256, IJBTerminal) external pure returns (bool) {
        return false;
    }

    function controllerOf(uint256) external pure returns (IERC165) {
        return IERC165(address(0));
    }
}

contract FreshNemesisRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FreshNemesis721Store {
    mapping(uint256 tokenId => JB721Tier tier) public tierOfToken;

    function setTokenTier(uint32 tokenId, uint16 votingUnits) external {
        JB721TierFlags memory flags;
        tierOfToken[tokenId] = JB721Tier({
            id: tokenId,
            price: 0,
            remainingSupply: 0,
            initialSupply: 1,
            votingUnits: votingUnits,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIpfsUri: bytes32(0),
            category: 0,
            discountPercent: 0,
            flags: flags,
            splitPercent: 0,
            resolvedUri: ""
        });
    }

    function tierOfTokenId(address, uint256 tokenId, bool) external view returns (JB721Tier memory) {
        return tierOfToken[tokenId];
    }
}

contract FreshNemesis721Checkpoints {
    FreshNemesis721Hook public hook;
    uint256 public totalSupply;
    mapping(address account => uint256 votes) public votesOf;

    function setHook(FreshNemesis721Hook hook_) external {
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
        return hook.ownerOfAt(tokenId, blockNumber);
    }
}

contract FreshNemesis721Hook {
    FreshNemesis721Store public immutable STORE;
    FreshNemesis721Checkpoints public immutable checkpoints;

    mapping(uint256 tokenId => address owner) public ownerOfToken;
    mapping(uint256 tokenId => mapping(uint256 blockNumber => address owner)) public historicalOwnerOf;

    constructor(FreshNemesis721Store store, FreshNemesis721Checkpoints checkpoints_) {
        STORE = store;
        checkpoints = checkpoints_;
        checkpoints_.setHook(this);
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = ownerOfToken[tokenId];
        require(owner != address(0), "invalid token");
        return owner;
    }

    function setOwner(uint256 tokenId, address owner) external {
        ownerOfToken[tokenId] = owner;
    }

    function setHistoricalOwner(uint256 tokenId, uint256 blockNumber, address owner) external {
        historicalOwnerOf[tokenId][blockNumber] = owner;
    }

    function ownerOfAt(uint256 tokenId, uint256 blockNumber) external view returns (address) {
        address historicalOwner = historicalOwnerOf[tokenId][blockNumber];
        if (historicalOwner != address(0)) return historicalOwner;
        return ownerOfToken[tokenId];
    }
}

contract FreshCodexNemesisDuplicate721ClaimTest is Test {
    function test_duplicateTokenIdRevertsBeforeConsumingSnapshotOwnerBudget() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address mallory = makeAddr("mallory");

        JB721Distributor distributor =
            new JB721Distributor(IJBDirectory(address(new FreshNemesisDirectory())), 1 days, 4, 0);
        FreshNemesisRewardToken reward = new FreshNemesisRewardToken();
        FreshNemesis721Store store = new FreshNemesis721Store();
        FreshNemesis721Checkpoints checkpoints = new FreshNemesis721Checkpoints();
        FreshNemesis721Hook hook = new FreshNemesis721Hook(store, checkpoints);

        store.setTokenTier(1, 50);
        store.setTokenTier(2, 50);
        store.setTokenTier(3, 50);
        hook.setOwner(1, alice);
        hook.setOwner(2, alice);
        hook.setOwner(3, alice);
        checkpoints.setVotes(alice, 150);
        checkpoints.setTotalSupply(150);

        reward.mint(address(this), 1500 ether);
        reward.approve(address(distributor), 1500 ether);
        distributor.fund(address(hook), IERC20(address(reward)), 1500 ether);

        (,, uint256 snapshotBlock,,) = distributor.rewardRoundOf(address(hook), IERC20(address(reward)), 0);
        for (uint256 tokenId = 1; tokenId <= 3; tokenId++) {
            hook.setHistoricalOwner(tokenId, snapshotBlock, alice);
        }

        hook.setOwner(1, mallory);
        hook.setOwner(2, bob);
        hook.setOwner(3, bob);

        vm.warp(distributor.roundStartTimestamp(1) + 1);
        vm.roll(block.number + 1);

        uint256[] memory duplicateIds = new uint256[](3);
        duplicateIds[0] = 1;
        duplicateIds[1] = 1;
        duplicateIds[2] = 1;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(JB721Distributor.JB721Distributor_DuplicateTokenId.selector, 1));
        distributor.beginVesting(address(hook), duplicateIds, tokens);

        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(reward))), 0);

        uint256[] memory bobIds = new uint256[](2);
        bobIds[0] = 2;
        bobIds[1] = 3;

        vm.prank(bob);
        distributor.beginVesting(address(hook), bobIds, tokens);

        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(reward))), 500 ether);
        assertEq(distributor.claimedFor(address(hook), 3, IERC20(address(reward))), 500 ether);
    }
}
