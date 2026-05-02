// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";

import {JB721Distributor} from "../../src/JB721Distributor.sol";
import {JBTokenDistributor} from "../../src/JBTokenDistributor.sol";

contract CodexNemesisToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CodexNemesisDirectory {
    address public terminal;
    IERC165 public controller;

    function setTerminal(address terminal_) external {
        terminal = terminal_;
    }

    function setController(IERC165 controller_) external {
        controller = controller_;
    }

    function isTerminalOf(uint256, IJBTerminal terminal_) external view returns (bool) {
        return address(terminal_) == terminal;
    }

    function controllerOf(uint256) external view returns (IERC165) {
        return controller;
    }
}

contract CodexNemesisVotes {
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

contract CodexNemesis721Store {
    uint104 public votingUnits = 100;

    function tierOfTokenId(address, uint256, bool) external view returns (JB721Tier memory tier) {
        tier.votingUnits = votingUnits;
        tier.initialSupply = 100;
    }

    /// @dev Returns 0 for all tokens (backward-compatible: allows vesting).
    function mintBlockOf(address, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract CodexNemesis721Checkpoints {
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
        return CodexNemesis721Hook(hook).ownerOfAt(tokenId, blockNumber);
    }
}

contract CodexNemesis721Hook {
    CodexNemesis721Store public immutable STORE;
    CodexNemesis721Checkpoints public immutable CHECKPOINTS;
    mapping(uint256 tokenId => address owner) public ownerOf;
    mapping(uint256 tokenId => uint256[] blocks) internal _ownerCheckpointBlocksOf;
    mapping(uint256 tokenId => mapping(uint256 blockNumber => address owner)) internal _ownerAtBlock;

    constructor(CodexNemesis721Store store, CodexNemesis721Checkpoints checkpoints) {
        STORE = store;
        CHECKPOINTS = checkpoints;
        CHECKPOINTS.setHook(address(this));
    }

    function mint(address owner, uint256 tokenId) external {
        ownerOf[tokenId] = owner;
        _recordOwner(tokenId, owner);
    }

    function burn(uint256 tokenId) external {
        delete ownerOf[tokenId];
        _recordOwner(tokenId, address(0));
    }

    function ownerOfAt(uint256 tokenId, uint256 blockNumber) external view returns (address) {
        uint256[] storage checkpointBlocks = _ownerCheckpointBlocksOf[tokenId];
        for (uint256 i = checkpointBlocks.length; i != 0;) {
            unchecked {
                --i;
            }
            uint256 checkpointBlock = checkpointBlocks[i];
            if (checkpointBlock <= blockNumber) return _ownerAtBlock[tokenId][checkpointBlock];
        }
        return address(0);
    }

    function _recordOwner(uint256 tokenId, address owner) internal {
        uint256[] storage checkpointBlocks = _ownerCheckpointBlocksOf[tokenId];
        if (checkpointBlocks.length != 0 && checkpointBlocks[checkpointBlocks.length - 1] == block.number) {
            _ownerAtBlock[tokenId][block.number] = owner;
            return;
        }

        checkpointBlocks.push(block.number);
        _ownerAtBlock[tokenId][block.number] = owner;
    }
}

contract CodexNemesisFreshVerificationTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant ROUND_DURATION = 1 days;
    uint256 internal constant VESTING_ROUNDS = 1;

    /// @notice Previously this test proved the attack worked. Now it proves the fix: sending ETH
    /// with context.token set to an ERC-20 address reverts with TokenMismatch.
    function test_nativeValueCanCreateUnbackedErc20CreditAndDrainOtherHookInventory() public {
        address attacker = makeAddr("attacker");
        address victimHook = makeAddr("victimHook");
        uint256 rewardAmount = 100_000_000; // 100 units of a 6-decimal token.

        CodexNemesisDirectory directory = new CodexNemesisDirectory();
        directory.setTerminal(address(this));

        JBTokenDistributor distributor =
            new JBTokenDistributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);
        CodexNemesisToken reward = new CodexNemesisToken();
        CodexNemesisVotes stake = new CodexNemesisVotes();
        stake.setVotes(attacker, 1 ether);
        stake.setTotalSupply(1 ether);

        reward.mint(address(this), rewardAmount);
        reward.approve(address(distributor), rewardAmount);
        distributor.fund(victimHook, IERC20(address(reward)), rewardAmount);

        JBSplit memory split = JBSplit({
            percent: 0,
            projectId: 0,
            beneficiary: payable(address(stake)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(0))
        });
        JBSplitHookContext memory context = JBSplitHookContext({
            token: address(reward),
            amount: rewardAmount,
            decimals: 6,
            projectId: PROJECT_ID,
            groupId: uint256(uint160(address(reward))),
            split: split
        });

        // FIX VERIFIED: The attack now reverts because context.token != NATIVE_TOKEN when msg.value != 0.
        vm.deal(address(this), rewardAmount);
        vm.expectRevert(JBTokenDistributor.JBTokenDistributor_TokenMismatch.selector);
        distributor.processSplitWith{value: rewardAmount}(context);

        // Victim's balance remains intact — attack blocked.
        assertEq(distributor.balanceOf(victimHook, IERC20(address(reward))), rewardAmount);
        assertEq(reward.balanceOf(address(distributor)), rewardAmount);
    }

    function test_721LateMintedTokenCannotClaimRoundSnapshotRewardsFromOwnersPastVotes() public {
        address alice = makeAddr("alice");

        CodexNemesisDirectory directory = new CodexNemesisDirectory();
        JB721Distributor distributor =
            new JB721Distributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);
        CodexNemesisToken reward = new CodexNemesisToken();
        CodexNemesis721Store store = new CodexNemesis721Store();
        CodexNemesis721Checkpoints checkpoints = new CodexNemesis721Checkpoints();
        CodexNemesis721Hook hook = new CodexNemesis721Hook(store, checkpoints);

        reward.mint(address(this), 100 ether);
        reward.approve(address(distributor), 100 ether);
        distributor.fund(address(hook), IERC20(address(reward)), 100 ether);

        hook.mint(alice, 1);
        checkpoints.setVotes(alice, 100);
        checkpoints.setTotalSupply(100);
        vm.roll(block.number + 1);
        distributor.poke();

        hook.burn(1);
        hook.mint(alice, 2);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 2;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));

        distributor.beginVesting(address(hook), tokenIds, tokens);

        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(reward))), 0);

        vm.warp(block.timestamp + ROUND_DURATION);
        vm.prank(alice);
        distributor.collectVestedRewards(address(hook), tokenIds, tokens, alice);

        assertEq(reward.balanceOf(alice), 0);
    }

    function test_721LateMintedReplacementCannotStealTransferredSnapshotTokensRoundRewards() public {
        address seller = makeAddr("seller");
        address buyer = makeAddr("buyer");

        CodexNemesisDirectory directory = new CodexNemesisDirectory();
        JB721Distributor distributor =
            new JB721Distributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);
        CodexNemesisToken reward = new CodexNemesisToken();
        CodexNemesis721Store store = new CodexNemesis721Store();
        CodexNemesis721Checkpoints checkpoints = new CodexNemesis721Checkpoints();
        CodexNemesis721Hook hook = new CodexNemesis721Hook(store, checkpoints);

        reward.mint(address(this), 100 ether);
        reward.approve(address(distributor), 100 ether);
        distributor.fund(address(hook), IERC20(address(reward)), 100 ether);

        // Token 1 is the snapshot-eligible NFT initially owned by the seller.
        hook.mint(seller, 1);
        checkpoints.setVotes(seller, 100);
        checkpoints.setTotalSupply(100);
        vm.roll(block.number + 1);
        distributor.poke();

        // After the snapshot, the seller transfers token 1 away and mints a new token 2.
        hook.mint(buyer, 1);
        hook.mint(seller, 2);

        uint256[] memory buyerTokenIds = new uint256[](1);
        buyerTokenIds[0] = 1;
        uint256[] memory sellerTokenIds = new uint256[](1);
        sellerTokenIds[0] = 2;
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(reward));

        // The late-minted replacement token cannot consume the seller's snapshot votes.
        distributor.beginVesting(address(hook), sellerTokenIds, tokens);
        // The real snapshot token now owned by the buyer can vest against the token's snapshot owner.
        distributor.beginVesting(address(hook), buyerTokenIds, tokens);

        assertEq(distributor.claimedFor(address(hook), 2, IERC20(address(reward))), 0);
        assertEq(distributor.claimedFor(address(hook), 1, IERC20(address(reward))), 100 ether);

        vm.warp(block.timestamp + ROUND_DURATION);
        vm.prank(buyer);
        distributor.collectVestedRewards(address(hook), buyerTokenIds, tokens, buyer);

        assertEq(reward.balanceOf(seller), 0, "seller cannot drain the round through the replacement token");
        assertEq(reward.balanceOf(buyer), 100 ether, "buyer of the snapshot token receives the round rewards");
    }
}
