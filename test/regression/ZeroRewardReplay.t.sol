// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";
import {JB721Distributor} from "../../src/JB721Distributor.sol";

contract MockDirectory {
    function isTerminalOf(uint256, IJBTerminal) external pure returns (bool) {
        return false;
    }

    function controllerOf(uint256) external pure returns (IERC165) {
        return IERC165(address(0));
    }
}

contract MockRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockStore {
    mapping(uint256 tokenId => JB721Tier tier) public tierOfToken;

    function setTokenTier(uint256 tokenId, uint104 votingUnits) external {
        JB721TierFlags memory flags;
        tierOfToken[tokenId] = JB721Tier({
            // This audit fixture only mints small token IDs, which fit the tier ID width.
            // forge-lint: disable-next-line(unsafe-typecast)
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

contract MockCheckpoints {
    MockHook public immutable hook;

    constructor(MockHook hook_) {
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

contract MockHook {
    MockStore public immutable store;
    MockCheckpoints public immutable checkpoints;
    address public immutable owner;

    constructor(MockStore store_, address owner_) {
        store = store_;
        owner = owner_;
        checkpoints = new MockCheckpoints(this);
    }

    function STORE() external view returns (MockStore) {
        return store;
    }

    function CHECKPOINTS() external view returns (MockCheckpoints) {
        return checkpoints;
    }

    function ownerOf(uint256) public view returns (address) {
        return owner;
    }
}

contract ZeroRewardReplayTest is Test {
    address internal alice = makeAddr("alice");

    function test_zeroRewardTokenCannotBeReplayedToExhaustOwnerVotingCap() public {
        MockStore store = new MockStore();
        MockHook hook = new MockHook(store, alice);
        MockRewardToken rewardToken = new MockRewardToken();
        IJBDirectory directory = IJBDirectory(address(new MockDirectory()));

        store.setTokenTier(1, 40);
        store.setTokenTier(2, 60);

        JB721Distributor control = new JB721Distributor(
            directory, IJBController(address(0)), IREVLoans(address(0)), IREVOwner(address(0)), 1 days, 4, 0
        );
        JB721Distributor attacked = new JB721Distributor(
            directory, IJBController(address(0)), IREVLoans(address(0)), IREVOwner(address(0)), 1 days, 4, 0
        );

        rewardToken.mint(address(this), 4);
        rewardToken.approve(address(control), 2);
        rewardToken.approve(address(attacked), 2);
        control.fund(address(hook), IERC20(address(rewardToken)), 2);
        attacked.fund(address(hook), IERC20(address(rewardToken)), 2);
        vm.warp(control.roundStartTimestamp(1) + 1);
        vm.roll(block.number + 1);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        uint256[] memory highValueToken = new uint256[](1);
        highValueToken[0] = 2;
        vm.prank(alice);
        control.beginVesting(address(hook), highValueToken, tokens);
        assertEq(control.claimedFor(address(hook), 2, IERC20(address(rewardToken))), 1);

        uint256[] memory dustToken = new uint256[](1);
        dustToken[0] = 1;
        vm.startPrank(alice);
        attacked.beginVesting(address(hook), dustToken, tokens);
        attacked.beginVesting(address(hook), dustToken, tokens);
        attacked.beginVesting(address(hook), dustToken, tokens);
        assertEq(attacked.claimedFor(address(hook), 1, IERC20(address(rewardToken))), 0);

        attacked.beginVesting(address(hook), highValueToken, tokens);
        vm.stopPrank();
        assertEq(attacked.claimedFor(address(hook), 2, IERC20(address(rewardToken))), 1);
    }
}
