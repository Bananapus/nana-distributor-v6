// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {JB721Distributor} from "../../src/JB721Distributor.sol";
import {JBDistributor} from "../../src/JBDistributor.sol";

contract CollectionReentryDirectory {}

contract CollectionReentryStore {
    function tierOfTokenId(address, uint256, bool) external pure returns (JB721Tier memory tier) {
        JB721TierFlags memory flags;
        tier = JB721Tier({
            id: 1,
            price: 0,
            remainingSupply: 0,
            initialSupply: 1,
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
}

contract CollectionReentryCheckpoints {
    address public hook;
    uint256 public totalSupply = 100;

    function setHook(address hook_) external {
        hook = hook_;
    }

    function getPastTotalSupply(uint256) external view returns (uint256) {
        return totalSupply;
    }

    function getPastVotes(address account, uint256) external view returns (uint256) {
        return account == CollectionReentryHook(hook).owner() ? 100 : 0;
    }

    function ownerOfAt(uint256 tokenId, uint256) external view returns (address) {
        return CollectionReentryHook(hook).ownerOf(tokenId);
    }
}

contract CollectionReentryHook {
    CollectionReentryStore public immutable STORE;
    CollectionReentryCheckpoints public immutable CHECKPOINTS;

    address public owner;

    constructor(CollectionReentryStore store, CollectionReentryCheckpoints checkpointsContract, address ownerAddress) {
        STORE = store;
        CHECKPOINTS = checkpointsContract;
        owner = ownerAddress;
        CHECKPOINTS.setHook(address(this));
    }

    function checkpoints() external view returns (CollectionReentryCheckpoints) {
        return CHECKPOINTS;
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        require(tokenId == 1 && owner != address(0), "NO_OWNER");
        return owner;
    }
}

contract CollectionReentryRewardToken is ERC20 {
    JB721Distributor public distributor;
    CollectionReentryHook public hook;

    bool public reentryEnabled;

    constructor() ERC20("Collection Reentry Reward", "CRR") {}

    function configure(JB721Distributor distributorAddress, CollectionReentryHook hookAddress) external {
        distributor = distributorAddress;
        hook = hookAddress;
    }

    function setReentryEnabled(bool enabled) external {
        reentryEnabled = enabled;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        super._update({from: from, to: to, value: amount});

        if (!reentryEnabled || to != address(distributor) || from == address(0) || amount == 0) return;

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(this));

        // Reenter as the NFT owner while the distributor is measuring this token's inbound balance delta.
        distributor.collectVestedRewards({
            hook: address(hook), tokenIds: tokenIds, tokens: tokens, beneficiary: address(this)
        });
    }
}

contract ReentrantRewardCollectionGuardTest is Test {
    uint256 internal constant ROUND_DURATION = 1;
    uint256 internal constant VESTING_ROUNDS = 1;

    address internal _funder = makeAddr("funder");

    JB721Distributor internal _distributor;
    CollectionReentryRewardToken internal _reward;
    CollectionReentryHook internal _hook;

    function setUp() public {
        _distributor = new JB721Distributor({
            directory: IJBDirectory(address(new CollectionReentryDirectory())),
            controller: IJBController(address(0)),
            revLoans: IREVLoans(address(0)),
            revOwner: IREVOwner(address(0)),
            initialRoundDuration: ROUND_DURATION,
            initialVestingRounds: VESTING_ROUNDS,
            initialClaimDuration: 0
        });
        _reward = new CollectionReentryRewardToken();
        _hook = new CollectionReentryHook({
            store: new CollectionReentryStore(),
            checkpointsContract: new CollectionReentryCheckpoints(),
            ownerAddress: address(_reward)
        });
        _reward.configure({distributorAddress: _distributor, hookAddress: _hook});

        _fundAndVestInitialRewards();
        vm.warp(_distributor.roundStartTimestamp(2) + 1);
    }

    function test_reentrantCollectDuringFundingRevertsBeforeUnderCredit() public {
        _reward.mint({to: _funder, amount: 100 ether});

        vm.prank(_funder);
        _reward.approve({spender: address(_distributor), value: 100 ether});

        _reward.setReentryEnabled(true);

        vm.prank(_funder);
        vm.expectRevert(
            abi.encodeWithSelector(JBDistributor.JBDistributor_ReentrantTokenTransfer.selector, address(_reward))
        );
        _distributor.fund({hook: address(_hook), token: IERC20(address(_reward)), amount: 100 ether});

        assertEq(_reward.balanceOf(address(_distributor)), 100 ether, "existing reward pool should stay backed");
        assertEq(
            _distributor.balanceOf(address(_hook), IERC20(address(_reward))),
            100 ether,
            "tracked hook balance should not be netted out"
        );
        assertEq(
            _distributor.totalVestingAmountOf(address(_hook), IERC20(address(_reward))),
            100 ether,
            "old vesting entry should remain collectable"
        );

        _reward.setReentryEnabled(false);
        vm.prank(address(_reward));
        _distributor.collectVestedRewards({
            hook: address(_hook),
            tokenIds: _singleTokenId(),
            tokens: _singleRewardToken(),
            beneficiary: address(_reward)
        });

        assertEq(_reward.balanceOf(address(_reward)), 100 ether, "owner can still collect after the guarded fund");
    }

    function _fundAndVestInitialRewards() internal {
        _reward.mint({to: address(this), amount: 100 ether});
        _reward.approve({spender: address(_distributor), value: 100 ether});
        _distributor.fund({hook: address(_hook), token: IERC20(address(_reward)), amount: 100 ether});
        vm.warp(_distributor.roundStartTimestamp(1) + 1);
        vm.roll(block.number + 1);
        vm.prank(address(_reward));
        _distributor.beginVesting({hook: address(_hook), tokenIds: _singleTokenId(), tokens: _singleRewardToken()});
    }

    function _singleRewardToken() internal view returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = IERC20(address(_reward));
    }

    function _singleTokenId() internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = 1;
    }
}
