// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";

import {JBDistributor} from "../../src/JBDistributor.sol";
import {JB721Distributor} from "../../src/JB721Distributor.sol";
import {JBTokenDistributor} from "../../src/JBTokenDistributor.sol";

contract RegressionDirectory {
    mapping(uint256 projectId => mapping(address terminal => bool)) public terminals;
    mapping(uint256 projectId => address controller) public controllers;

    function setTerminal(uint256 projectId, address terminal, bool isTerminal) external {
        terminals[projectId][terminal] = isTerminal;
    }

    function setController(uint256 projectId, address controller) external {
        controllers[projectId] = controller;
    }

    function isTerminalOf(uint256 projectId, IJBTerminal terminal) external view returns (bool) {
        return terminals[projectId][address(terminal)];
    }

    function controllerOf(uint256 projectId) external view returns (IERC165) {
        return IERC165(controllers[projectId]);
    }
}

contract RegressionRewardToken is ERC20 {
    constructor() ERC20("Reward", "RWD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RegressionVotesToken is ERC20, ERC20Votes {
    constructor() ERC20("Votes", "VOTE") EIP712("Votes", "1") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}

contract RegressionStore {
    uint256 public maxTier;
    mapping(uint256 tierId => JB721Tier) public tiers;
    mapping(uint256 tokenId => uint256 tierId) public tokenTiers;

    function setMaxTierIdOf(uint256 maxTierId) external {
        maxTier = maxTierId;
    }

    function setTier(uint256 tierId, JB721Tier memory tier) external {
        tiers[tierId] = tier;
    }

    function setTokenTier(uint256 tokenId, uint256 tierId) external {
        tokenTiers[tokenId] = tierId;
    }

    function tierOfTokenId(address, uint256 tokenId, bool) external view returns (JB721Tier memory) {
        return tiers[tokenTiers[tokenId]];
    }

    /// @dev Returns 0 for all tokens (backward-compatible: allows vesting).
    function mintBlockOf(address, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract RegressionCheckpoints {
    uint256 public totalSupplyAtSnapshot;
    mapping(address account => uint256 votes) public votesAtSnapshot;
    address public hook;

    function setHook(address hook_) external {
        hook = hook_;
    }

    function setTotalSupply(uint256 totalSupply) external {
        totalSupplyAtSnapshot = totalSupply;
    }

    function setVotes(address account, uint256 votes) external {
        votesAtSnapshot[account] = votes;
    }

    function getPastTotalSupply(uint256) external view returns (uint256) {
        return totalSupplyAtSnapshot;
    }

    function getPastVotes(address account, uint256) external view returns (uint256) {
        return votesAtSnapshot[account];
    }

    function ownerOfAt(uint256 tokenId, uint256 blockNumber) external view returns (address) {
        return RegressionHook(hook).ownerOfAt(tokenId, blockNumber);
    }
}

contract RegressionHook {
    RegressionStore public immutable STORE;
    RegressionCheckpoints public immutable CHECKPOINTS;

    mapping(uint256 tokenId => address owner) public owners;
    mapping(uint256 tokenId => address owner) public snapshotOwners;

    constructor(RegressionStore store, RegressionCheckpoints checkpoints) {
        STORE = store;
        CHECKPOINTS = checkpoints;
        CHECKPOINTS.setHook(address(this));
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        address owner = owners[tokenId];
        require(owner != address(0), "NO_OWNER");
        return owner;
    }

    function ownerOfAt(uint256 tokenId, uint256) external view returns (address) {
        return snapshotOwners[tokenId];
    }

    function setOwner(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
    }

    function setSnapshotOwner(uint256 tokenId, address owner) external {
        snapshotOwners[tokenId] = owner;
    }
}

contract RegressionAccountingTest is Test {
    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant ROUND_DURATION = 100;
    uint256 internal constant VESTING_ROUNDS = 4;

    address internal attacker = makeAddr("attacker");
    address internal honest = makeAddr("honest");
    address internal maliciousController = makeAddr("maliciousController");

    RegressionDirectory internal directory;
    RegressionRewardToken internal rewardToken;

    function setUp() public {
        directory = new RegressionDirectory();
        rewardToken = new RegressionRewardToken();
        directory.setController(PROJECT_ID, maliciousController);
    }

    function test_controllerCanCreditUndeliveredTokensAndDrainRealInventory() public {
        JBTokenDistributor distributor =
            new JBTokenDistributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);
        RegressionVotesToken votesToken = new RegressionVotesToken();

        votesToken.mint(attacker, 10 ether);
        votesToken.mint(honest, 990 ether);

        vm.prank(attacker);
        votesToken.delegate(attacker);
        vm.prank(honest);
        votesToken.delegate(honest);
        vm.roll(block.number + 1);

        rewardToken.mint(address(this), 1000 ether);
        rewardToken.approve(address(distributor), 1000 ether);
        distributor.fund(address(votesToken), IERC20(address(rewardToken)), 1000 ether);

        JBSplit memory split = JBSplit({
            percent: 1_000_000_000,
            projectId: 0,
            beneficiary: payable(address(votesToken)),
            preferAddToBalance: false,
            lockedUntil: 0,
            hook: IJBSplitHook(address(distributor))
        });
        JBSplitHookContext memory fakeContext = JBSplitHookContext({
            token: address(rewardToken),
            amount: 99_000 ether,
            decimals: 18,
            projectId: PROJECT_ID,
            groupId: 0,
            split: split
        });

        // FIX: The malicious controller did not actually transfer tokens, so the
        // balance-delta check reverts with UnfundedSplitCredit.
        vm.prank(maliciousController);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBDistributor.JBDistributor_UnfundedSplitCredit.selector, address(rewardToken), 99_000 ether, 0
            )
        );
        distributor.processSplitWith(fakeContext);

        // The real balance should remain intact — the attack was blocked.
        assertEq(rewardToken.balanceOf(address(distributor)), 1000 ether, "balance unchanged after blocked attack");
        assertEq(
            distributor.balanceOf(address(votesToken), IERC20(address(rewardToken))),
            1000 ether,
            "tracked balance was not inflated"
        );
    }

    function test_721LateMintWithoutSnapshotOwnerCannotUseOwnersPastVotes() public {
        JB721Distributor distributor =
            new JB721Distributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);
        RegressionStore store = new RegressionStore();
        RegressionCheckpoints checkpoints = new RegressionCheckpoints();
        RegressionHook hook = new RegressionHook(store, checkpoints);

        JB721TierFlags memory flags;
        store.setMaxTierIdOf(1);
        store.setTier({
            tierId: 1,
            tier: JB721Tier({
                id: 1,
                price: 1 ether,
                remainingSupply: 97,
                initialSupply: 100,
                votingUnits: 100,
                reserveFrequency: 0,
                reserveBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                category: 0,
                discountPercent: 0,
                flags: flags,
                splitPercent: 0,
                resolvedUri: ""
            })
        });

        store.setTokenTier(1, 1);
        store.setTokenTier(2, 1);
        store.setTokenTier(3, 1);
        hook.setOwner(1, attacker);
        hook.setOwner(2, attacker);
        hook.setOwner(3, attacker);

        checkpoints.setTotalSupply(100);
        checkpoints.setVotes(attacker, 100);

        rewardToken.mint(address(this), 1000 ether);
        rewardToken.approve(address(distributor), 1000 ether);
        distributor.fund(address(hook), IERC20(address(rewardToken)), 1000 ether);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        uint256[] memory firstLateMint = new uint256[](1);
        firstLateMint[0] = 2;
        distributor.beginVesting(address(hook), firstLateMint, tokens);

        assertEq(distributor.claimedFor(address(hook), 2, tokens[0]), 0);
        assertEq(
            distributor.totalVestingAmountOf(address(hook), tokens[0]),
            0,
            "post-snapshot token without ownerOfAt eligibility cannot consume the snapshot"
        );
        assertEq(distributor.balanceOf(address(hook), tokens[0]), 1000 ether, "funded balance remains available");
    }

    function test_721SnapshotVotesCannotBeReusedAcrossSeparateSnapshotTokenClaims() public {
        JB721Distributor distributor =
            new JB721Distributor(IJBDirectory(address(directory)), ROUND_DURATION, VESTING_ROUNDS);
        RegressionStore store = new RegressionStore();
        RegressionCheckpoints checkpoints = new RegressionCheckpoints();
        RegressionHook hook = new RegressionHook(store, checkpoints);

        JB721TierFlags memory flags;
        store.setMaxTierIdOf(1);
        store.setTier({
            tierId: 1,
            tier: JB721Tier({
                id: 1,
                price: 1 ether,
                remainingSupply: 97,
                initialSupply: 100,
                votingUnits: 100,
                reserveFrequency: 0,
                reserveBeneficiary: address(0),
                encodedIPFSUri: bytes32(0),
                category: 0,
                discountPercent: 0,
                flags: flags,
                splitPercent: 0,
                resolvedUri: ""
            })
        });

        store.setTokenTier(1, 1);
        store.setTokenTier(2, 1);
        store.setTokenTier(3, 1);
        hook.setOwner(1, attacker);
        hook.setOwner(2, attacker);
        hook.setOwner(3, attacker);
        hook.setSnapshotOwner(2, attacker);
        hook.setSnapshotOwner(3, attacker);

        checkpoints.setTotalSupply(100);
        checkpoints.setVotes(attacker, 100);

        rewardToken.mint(address(this), 1000 ether);
        rewardToken.approve(address(distributor), 1000 ether);
        distributor.fund(address(hook), IERC20(address(rewardToken)), 1000 ether);

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(rewardToken));

        uint256[] memory firstLateMint = new uint256[](1);
        firstLateMint[0] = 2;
        distributor.beginVesting(address(hook), firstLateMint, tokens);

        uint256[] memory secondLateMint = new uint256[](1);
        secondLateMint[0] = 3;
        distributor.beginVesting(address(hook), secondLateMint, tokens);

        // FIX: With persistent consumed-votes tracking, the second beginVesting sees
        // that all 100 votes are already consumed, so token 3 gets 0 reward.
        assertEq(distributor.claimedFor(address(hook), 2, tokens[0]), 1000 ether);
        assertEq(distributor.claimedFor(address(hook), 3, tokens[0]), 0, "votes already consumed, no double-claim");
        assertEq(
            distributor.totalVestingAmountOf(address(hook), tokens[0]),
            1000 ether,
            "total vesting capped at funded balance"
        );
        assertLe(
            distributor.totalVestingAmountOf(address(hook), tokens[0]),
            distributor.balanceOf(address(hook), tokens[0]),
            "vesting obligations do not exceed funded balance"
        );

        // Collection should succeed without underflow.
        vm.warp(distributor.roundStartTimestamp(VESTING_ROUNDS) + 1);
        vm.roll(block.number + 1);
        vm.prank(attacker);
        distributor.collectVestedRewards(address(hook), firstLateMint, tokens, attacker);
        assertEq(rewardToken.balanceOf(attacker), 1000 ether, "attacker gets only their fair share");
    }
}
