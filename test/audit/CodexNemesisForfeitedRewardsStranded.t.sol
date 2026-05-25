// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";

import {JB721Distributor} from "../../src/JB721Distributor.sol";

contract CodexNemesisRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract CodexNemesisJBTokens {
    mapping(IJBToken token => uint256 projectId) public projectIdOf;
    mapping(uint256 projectId => IJBToken token) public tokenOf;

    function setToken(uint256 projectId, IJBToken token) external {
        projectIdOf[token] = projectId;
        tokenOf[projectId] = token;
    }
}

contract CodexNemesisJBController {
    CodexNemesisJBTokens public immutable tokens;

    constructor(CodexNemesisJBTokens tokens_) {
        tokens = tokens_;
    }

    function TOKENS() external view returns (CodexNemesisJBTokens) {
        return tokens;
    }

    function burnTokensOf(address holder, uint256 projectId, uint256 tokenCount, string calldata) external {
        tokens.tokenOf(projectId).burn(holder, tokenCount);
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
    JB721Tier internal _tier;
    uint256 public burned;

    constructor() {
        JB721TierFlags memory flags;
        _tier = JB721Tier({
            id: 1,
            price: 1 ether,
            remainingSupply: 0,
            initialSupply: 3,
            votingUnits: 100,
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

    function tierOfTokenId(address, uint256, bool) external view returns (JB721Tier memory) {
        return _tier;
    }

    function setBurned(uint256 count) external {
        burned = count;
    }
}

contract CodexNemesis721Checkpoints {
    CodexNemesis721Hook public hook;

    constructor(CodexNemesis721Hook hook_) {
        hook = hook_;
    }

    function getPastTotalSupply(uint256) external view returns (uint256) {
        return (3 - hook.STORE().burned()) * 100;
    }

    function getPastVotes(address account, uint256) external pure returns (uint256) {
        return account == address(0) ? 0 : 100;
    }

    function ownerOfAt(uint256 tokenId, uint256) external view returns (address) {
        return hook.historicalOwnerOf(tokenId);
    }
}

contract CodexNemesis721Hook {
    CodexNemesis721Store public immutable STORE;
    CodexNemesis721Checkpoints public immutable checkpoints;

    mapping(uint256 tokenId => address owner) internal _ownerOf;
    mapping(uint256 tokenId => address owner) public historicalOwnerOf;

    constructor() {
        STORE = new CodexNemesis721Store();
        checkpoints = new CodexNemesis721Checkpoints(this);
    }

    function setOwner(uint256 tokenId, address owner) external {
        _ownerOf[tokenId] = owner;
        historicalOwnerOf[tokenId] = owner;
    }

    function burn(uint256 tokenId) external {
        delete _ownerOf[tokenId];
        STORE.setBurned(1);
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = _ownerOf[tokenId];
        require(owner != address(0), "NOT_OWNED");
        return owner;
    }
}

contract CodexNemesisForfeitedRewardsBurnedTest is Test {
    uint256 internal constant ROUND_DURATION = 1 days;
    uint256 internal constant VESTING_ROUNDS = 1;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function test_forfeitedRewardsAreBurnedInsteadOfStranded() public {
        CodexNemesisRewardToken reward = new CodexNemesisRewardToken();
        CodexNemesisJBTokens jbTokens = new CodexNemesisJBTokens();
        jbTokens.setToken(1, IJBToken(address(reward)));

        JB721Distributor distributor = new JB721Distributor({
            directory: IJBDirectory(address(new CodexNemesisDirectory())),
            controller: IJBController(address(new CodexNemesisJBController(jbTokens))),
            revLoans: IREVLoans(address(0)),
            revOwner: IREVOwner(address(0)),
            initialRoundDuration: ROUND_DURATION,
            initialVestingRounds: VESTING_ROUNDS,
            initialClaimDuration: 0
        });
        CodexNemesis721Hook hook = new CodexNemesis721Hook();

        hook.setOwner(1, alice);
        hook.setOwner(2, bob);
        hook.setOwner(3, carol);

        reward.mint(address(this), 300 ether);
        reward.approve(address(distributor), 300 ether);
        distributor.fund(address(hook), IERC20(address(reward)), 300 ether);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));

        vm.warp(distributor.roundStartTimestamp(1) + 1);
        vm.roll(block.number + 1);

        vm.prank(alice);
        distributor.beginVesting(address(hook), _ids(1), tokens);
        vm.prank(bob);
        distributor.beginVesting(address(hook), _ids(2), tokens);
        vm.prank(carol);
        distributor.beginVesting(address(hook), _ids(3), tokens);
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(reward))), 300 ether);

        vm.warp(distributor.roundStartTimestamp(2) + 1);
        vm.roll(block.number + 1);

        hook.burn(1);
        distributor.releaseForfeitedRewards(address(hook), _ids(1), tokens, address(0));

        vm.prank(bob);
        distributor.collectVestedRewards(address(hook), _ids(2), tokens, bob);
        vm.prank(carol);
        distributor.collectVestedRewards(address(hook), _ids(3), tokens, carol);

        assertEq(distributor.balanceOf(address(hook), IERC20(address(reward))), 0);
        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(reward))), 0);
        assertEq(reward.balanceOf(address(distributor)), 0);
        assertEq(reward.totalSupply(), 200 ether);
        (uint256 roundAmount,, uint256 roundClaimedAmount,, uint256 roundTotalStake) =
            distributor.rewardRoundOf(address(hook), IERC20(address(reward)), 2);
        assertEq(roundAmount, 0);
        assertEq(roundClaimedAmount, 0);
        assertEq(roundTotalStake, 0);

        vm.warp(distributor.roundStartTimestamp(3) + 1);
        vm.roll(block.number + 1);

        vm.prank(bob);
        distributor.beginVesting(address(hook), _ids(2), tokens);
        vm.prank(carol);
        distributor.beginVesting(address(hook), _ids(3), tokens);

        assertEq(distributor.totalVestingAmountOf(address(hook), IERC20(address(reward))), 0);
        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(reward))), 0);
        assertEq(distributor.claimedFor(address(hook), 3, IERC20(address(reward))), 0);
        assertEq(distributor.balanceOf(address(hook), IERC20(address(reward))), 0);
    }

    function _ids(uint256 tokenId) internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
    }
}
