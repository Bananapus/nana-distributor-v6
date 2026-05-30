// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";
import {REVLoan} from "@rev-net/core-v6/src/structs/REVLoan.sol";

import {IJBDistributor} from "./interfaces/IJBDistributor.sol";
import {JBVestingMath} from "./libraries/JBVestingMath.sol";
import {JBBorrowContext} from "./structs/JBBorrowContext.sol";
import {JBRewardRoundData} from "./structs/JBRewardRoundData.sol";
import {JBVestingData} from "./structs/JBVestingData.sol";
import {JBVestingLoan} from "./structs/JBVestingLoan.sol";

/// @notice Abstract base for reward distributors. Manages round-based distribution of ERC-20 tokens (or native ETH)
/// to stakers with linear vesting. Each round, a snapshot is taken of the distributable balance, and stakers can
/// claim their pro-rata share based on their stake weight at the snapshot block. Claimed tokens vest linearly over
/// `VESTING_ROUNDS` rounds and can be collected as they unlock.
/// @dev Subclasses define how stake is measured (`_tokenStake`, `_totalStake`), who can claim (`_canClaim`), and
/// what "burned" means (`_tokenBurned`). Two concrete implementations exist: `JBTokenDistributor` (IVotes tokens)
/// and `JB721Distributor` (Juicebox 721 NFTs).
abstract contract JBDistributor is IJBDistributor {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when an empty tokenIds array is passed.
    error JBDistributor_EmptyTokenIds(uint256 tokenIdCount);

    /// @notice Thrown when a repaid Revnet loan returned less collateral than it originally borrowed.
    error JBDistributor_InsufficientRepaidCollateral(uint256 expectedAmount, uint256 actualAmount);

    /// @notice Thrown when the provided repayment amount is less than the amount needed to repay a loan.
    error JBDistributor_InsufficientRepayAmount(uint256 amount, uint256 requiredAmount);

    /// @notice Thrown when the Revnet loans contract returns a reserved loan ID.
    error JBDistributor_InvalidVestingLoanId(uint256 loanId);

    /// @notice Thrown when the round duration is zero.
    error JBDistributor_InvalidRoundDuration(uint256 roundDuration);

    /// @notice Thrown when a native ETH transfer fails.
    error JBDistributor_NativeTransferFailed(address beneficiary, uint256 amount);

    /// @notice Thrown when the caller does not have access to the token.
    error JBDistributor_NoAccess(address hook, uint256 tokenId, address account);

    /// @notice Thrown when there are no uncollected vesting revnet tokens to collateralize a loan.
    error JBDistributor_NothingToBorrow(address hook, address token);

    /// @notice Thrown when a loan ID is not tracking distributor-owned vesting collateral.
    error JBDistributor_NoVestingLoan(uint256 loanId);

    /// @notice Thrown when a reward token is not a revnet token owned by the configured REVOwner.
    error JBDistributor_NotRevnetRewardToken(address token);

    /// @notice Thrown when an ERC-20 reenters a funding balance-delta measurement.
    error JBDistributor_ReentrantTokenTransfer(address token);

    /// @notice Thrown when revnet loan-backed collection has not been configured.
    error JBDistributor_RevnetLoansNotConfigured();

    /// @notice Thrown when a tier-scoped call's tier IDs are not strictly increasing (so a canonical group ID
    /// cannot be derived).
    error JBDistributor_TierIdsNotIncreasing(uint256 previousTierId, uint256 tierId);

    /// @notice Thrown when unexpected native ETH is sent with an ERC-20 operation.
    error JBDistributor_UnexpectedNativeValue(uint256 msgValue, address token);

    /// @notice Thrown when an ERC-20 repayment does not credit the exact amount pulled from the caller.
    error JBDistributor_UnexpectedRepayAmount(uint256 amount, uint256 expectedAmount);

    /// @notice Thrown when a function requires exactly one reward token.
    error JBDistributor_UnexpectedTokenCount(uint256 tokenCount);

    /// @notice Thrown when a token ID has an outstanding loan against its vesting rewards.
    error JBDistributor_VestingLoanOutstanding(address hook, uint256 tokenId, address token, uint256 loanId);

    /// @notice Thrown when a vesting loan is written off before Revnet has liquidated it.
    error JBDistributor_VestingLoanNotLiquidated(uint256 loanId);

    /// @notice Thrown when vesting loans are requested from a distributor with no vesting period.
    error JBDistributor_VestingLoansDisabled();

    /// @notice Thrown when a value cannot fit in a uint208 reward-round field.
    error JBDistributor_Uint208Overflow(uint256 value);

    /// @notice Thrown when a value cannot fit in a uint48 field.
    error JBDistributor_Uint48Overflow(uint256 value);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The number of shares that represent 100%.
    uint256 public constant MAX_SHARE = 100_000;

    //*********************************************************************//
    // ----------------------- internal constants ------------------------ //
    //*********************************************************************//

    /// @notice Sentinel used before `REV_LOANS.borrowFrom` returns the real loan ID.
    uint256 internal constant _PENDING_VESTING_LOAN_ID = type(uint256).max;

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The number of seconds after a reward round becomes claimable before unclaimed rewards expire.
    /// @dev A zero duration means reward rounds do not expire.
    uint48 public immutable override CLAIM_DURATION;

    /// @notice The JB controller used for token registry lookups and revnet loan permissions.
    IJBController public immutable override CONTROLLER;

    /// @notice The duration of each round, specified in seconds.
    uint256 public immutable override ROUND_DURATION;

    /// @notice The Revnet loans contract used to borrow against vested revnet rewards.
    IREVLoans public immutable override REV_LOANS;

    /// @notice The REVOwner contract that must own a reward token's project to enable loan-backed collection.
    IREVOwner public immutable override REV_OWNER;

    /// @notice The starting timestamp of the distributor.
    uint256 public immutable override STARTING_TIMESTAMP;

    /// @notice The number of rounds until tokens are fully vested.
    uint256 public immutable override VESTING_ROUNDS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The active Revnet loan using one token ID's vesting rewards as collateral.
    /// @custom:param hook The hook the token ID belongs to.
    /// @custom:param groupId The reward group (0 = legacy all-tiers group).
    /// @custom:param tokenId The token ID whose vesting rewards are collateralized.
    /// @custom:param token The reward token used as loan collateral.
    mapping(address hook => mapping(uint256 groupId => mapping(uint256 tokenId => mapping(IERC20 token => uint256))))
        public
        override activeVestingLoanIdOf;

    /// @notice The index within `vestingDataOf` of the latest vest.
    /// @custom:param hook The hook the tokenId belongs to.
    /// @custom:param groupId The reward group (0 = legacy all-tiers group).
    /// @custom:param tokenId The ID of the token to which the vests belong.
    /// @custom:param token The address of the token vested.
    mapping(
        address hook => mapping(uint256 groupId => mapping(uint256 tokenId => mapping(IERC20 token => uint256)))
    ) public latestVestedIndexOf;

    /// @notice The block number recorded as the snapshot point for each round.
    /// @dev Set to `block.number - 1` on first interaction in a round, so that `IVotes.getPastVotes` works.
    mapping(uint256 round => uint256) public override roundSnapshotBlock;

    /// @notice Reward data assigned to each funding round.
    /// @custom:param hook The stake source whose stakers receive rewards.
    /// @custom:param groupId The reward group (0 = legacy all-tiers group).
    /// @custom:param token The reward token.
    /// @custom:param round The reward round.
    mapping(
        address hook => mapping(uint256 groupId => mapping(IERC20 token => mapping(uint256 round => JBRewardRoundData)))
    ) public rewardRoundOf;

    /// @notice The amount of a token that is currently vesting for a hook's stakers.
    /// @custom:param hook The hook whose stakers are vesting.
    /// @custom:param token The address of the token that is vesting.
    mapping(address hook => mapping(IERC20 token => uint256 amount)) public override totalVestingAmountOf;

    /// @notice The amount of vesting inventory currently collateralized in Revnet loans.
    /// @custom:param hook The hook whose stakers own the vesting rewards.
    /// @custom:param token The reward token used as loan collateral.
    mapping(address hook => mapping(IERC20 token => uint256 amount)) public override totalLoanedVestingAmountOf;

    /// @notice All vesting data of a tokenId for any number of vesting tokens.
    /// @custom:param hook The hook the tokenId belongs to.
    /// @custom:param groupId The reward group (0 = legacy all-tiers group).
    /// @custom:param tokenId The ID of the token to which the vests belong.
    /// @custom:param token The address of the token vested.
    mapping(
        address hook => mapping(uint256 groupId => mapping(uint256 tokenId => mapping(IERC20 token => JBVestingData[])))
    ) public vestingDataOf;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The total accounted balance of each token across all hooks.
    /// @custom:param token The token to check the accounted balance of.
    mapping(IERC20 token => uint256) internal _accountedBalanceOf;

    /// @notice The balance of a token held for a specific hook's stakers.
    /// @custom:param hook The hook whose balance to check.
    /// @custom:param token The token to check the balance of.
    mapping(address hook => mapping(IERC20 token => uint256)) internal _balanceOf;

    /// @notice The tier set that defines a reward group, recorded the first time the group is funded.
    /// @dev Empty for the legacy all-tiers group (0). Subclasses read this to scope the tier-set stake math.
    /// @custom:param hook The hook the group belongs to.
    /// @custom:param groupId The reward group.
    mapping(address hook => mapping(uint256 groupId => uint256[])) internal _tierIdsOfGroup;

    /// @notice The vesting position collateralized by a Revnet loan.
    /// @custom:param loanId The Revnet loan NFT ID.
    mapping(uint256 loanId => JBVestingLoan) internal _vestingLoanOf;

    //*********************************************************************//
    // ------------------- transient stored properties ------------------- //
    //*********************************************************************//

    /// @notice The ERC-20 whose incoming balance delta is currently being measured.
    address transient _acceptingToken;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param controller The JB controller used for token registry lookups and revnet loan permissions.
    /// @param revLoans The Revnet loans contract used to borrow against vested revnet rewards.
    /// @param revOwner The REVOwner contract that must own revnet reward token projects.
    /// @param initialRoundDuration The duration of each round, specified in seconds.
    /// @param initialVestingRounds The number of rounds until tokens are fully vested.
    /// @param initialClaimDuration The number of seconds claimants have after each reward round becomes claimable.
    constructor(
        IJBController controller,
        IREVLoans revLoans,
        IREVOwner revOwner,
        uint256 initialRoundDuration,
        uint256 initialVestingRounds,
        uint48 initialClaimDuration
    ) {
        if (initialRoundDuration == 0) {
            revert JBDistributor_InvalidRoundDuration({roundDuration: initialRoundDuration});
        }
        CLAIM_DURATION = initialClaimDuration;
        CONTROLLER = controller;
        REV_LOANS = revLoans;
        REV_OWNER = revOwner;
        STARTING_TIMESTAMP = block.timestamp;
        ROUND_DURATION = initialRoundDuration;
        VESTING_ROUNDS = initialVestingRounds;

        // Let the trusted Revnet loans contract burn this distributor's project-token rewards as collateral.
        if (address(revLoans) != address(0)) {
            uint8[] memory permissionIds = new uint8[](1);
            permissionIds[0] = JBPermissionIds.BURN_TOKENS;
            IJBPermissions permissions = IJBPermissioned(address(controller)).PERMISSIONS();
            permissions.setPermissionsFor({
                account: address(this),
                permissionsData: JBPermissionsData({
                    operator: address(revLoans), projectId: 0, permissionIds: permissionIds
                })
            });
        }
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Begin vesting all unclaimed past reward rounds for the specified token IDs.
    /// @dev Materializes each token ID's pro-rata share of every past (non-current) reward round into fresh vesting
    /// entries that start now and unlock over `VESTING_ROUNDS`. Current-round funding is excluded until a later round
    /// starts. The model-specific per-round claim math and the authorization check live in the `_claimPastRewards`
    /// and `_requireCanClaimTokenIds` hooks each concrete distributor implements.
    /// @param hook The hook (IVotes token or 721 hook) whose stakers are vesting.
    /// @param tokenIds The staker token IDs to claim rewards for.
    /// @param tokens The reward tokens to begin vesting.
    function beginVesting(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens
    )
        external
        virtual
        override
    {
        _beginVesting({hook: hook, groupId: 0, tokenIds: tokenIds, tokens: tokens});
    }

    /// @notice Begin vesting all unclaimed past reward rounds for the specified token IDs in a tier-scoped group.
    /// @param hook The hook (721 hook) whose stakers are vesting.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenIds The staker token IDs to claim rewards for.
    /// @param tokens The reward tokens to begin vesting.
    function beginVesting(
        address hook,
        uint256[] calldata tierIds,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens
    )
        external
        virtual
        override
    {
        _beginVesting({hook: hook, groupId: _groupIdFor(tierIds), tokenIds: tokenIds, tokens: tokens});
    }

    /// @notice Directly fund the distributor for a specific hook by pulling tokens from the caller. An alternative
    /// to split-based funding — useful for one-off deposits or external reward sources.
    /// @dev For native ETH, send `msg.value` and pass `IERC20(JBConstants.NATIVE_TOKEN)` as the token. Uses balance
    /// delta to handle fee-on-transfer tokens correctly.
    /// @param hook The hook to fund (determines which staker pool receives the tokens).
    /// @param token The token to fund with.
    /// @param amount The amount to fund (ignored for native ETH — `msg.value` is used instead).
    function fund(address hook, IERC20 token, uint256 amount) external payable virtual override {
        _fund({hook: hook, groupId: 0, tierIds: new uint256[](0), token: token, amount: amount});
    }

    /// @notice Fund a tier-scoped reward group: only holders of the given tiers can claim this pot.
    /// @dev For native ETH, send `msg.value` and pass `IERC20(JBConstants.NATIVE_TOKEN)` as the token. Uses balance
    /// delta to handle fee-on-transfer tokens correctly. The tier set is recorded on the group's first funding.
    /// @param hook The hook to fund (determines which staker pool receives the tokens).
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param token The token to fund with.
    /// @param amount The amount to fund (ignored for native ETH — `msg.value` is used instead).
    function fund(
        address hook,
        uint256[] calldata tierIds,
        IERC20 token,
        uint256 amount
    )
        external
        payable
        virtual
        override
    {
        _fund({hook: hook, groupId: _groupIdFor(tierIds), tierIds: tierIds, token: token, amount: amount});
    }

    /// @notice Recycle unclaimed rewards from expired reward rounds into the current reward round.
    /// @dev The selector name is kept for compatibility with existing keeper integrations.
    /// @param hook The hook whose expired rewards should be recycled.
    /// @param token The reward token to recycle.
    /// @param rounds The reward rounds to recycle.
    /// @return amount The total amount recycled.
    function burnExpiredRewards(
        address hook,
        IERC20 token,
        uint256[] calldata rounds
    )
        external
        virtual
        override
        returns (uint256 amount)
    {
        amount = _burnExpiredRewards({hook: hook, groupId: 0, token: token, rounds: rounds});
    }

    /// @notice Recycle unclaimed rewards from expired tier-scoped reward rounds into the current reward round.
    /// @param hook The hook whose expired rewards should be recycled.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param token The reward token to recycle.
    /// @param rounds The reward rounds to recycle.
    /// @return amount The total amount recycled.
    function burnExpiredRewards(
        address hook,
        uint256[] calldata tierIds,
        IERC20 token,
        uint256[] calldata rounds
    )
        external
        virtual
        override
        returns (uint256 amount)
    {
        amount = _burnExpiredRewards({hook: hook, groupId: _groupIdFor(tierIds), token: token, rounds: rounds});
    }

    /// @notice Record the snapshot block for the current round (and eagerly for the next round). Callable by anyone —
    /// keepers or frontends can call this early in a round to lock the snapshot block before any claims occur.
    function poke() external override {
        _ensureSnapshotBlock(currentRound());
    }

    /// @notice Recycle unlocked rewards tied to burned tokens into the current reward round.
    /// @dev Anyone can call this for burned tokens.
    /// @param hook The hook whose tokens were burned.
    /// @param tokenIds The IDs of the burned tokens (reverts if any are not actually burned).
    /// @param tokens The reward tokens to recycle.
    /// @param beneficiary Unused for forfeiture. Kept for interface compatibility.
    function releaseForfeitedRewards(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external
        override
    {
        _releaseForfeitedRewards({hook: hook, groupId: 0, tokenIds: tokenIds, tokens: tokens, beneficiary: beneficiary});
    }

    /// @notice Recycle unlocked rewards tied to burned tokens in a tier-scoped group into the current reward round.
    /// @dev Anyone can call this for burned tokens.
    /// @param hook The hook whose tokens were burned.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenIds The IDs of the burned tokens (reverts if any are not actually burned).
    /// @param tokens The reward tokens to recycle.
    /// @param beneficiary Unused for forfeiture. Kept for interface compatibility.
    function releaseForfeitedRewards(
        address hook,
        uint256[] calldata tierIds,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external
        override
    {
        _releaseForfeitedRewards({
            hook: hook,
            groupId: _groupIdFor(tierIds),
            tokenIds: tokenIds,
            tokens: tokens,
            beneficiary: beneficiary
        });
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The balance of a token held for a specific hook's stakers.
    /// @param hook The hook whose balance to check.
    /// @param token The token to check the balance of.
    function balanceOf(address hook, IERC20 token) external view override returns (uint256) {
        return _balanceOf[hook][token];
    }

    /// @notice Calculate the total amount of a reward token that has been claimed (began vesting) for a given
    /// staker token ID but has not yet been collected. Includes both locked (still vesting) and unlocked amounts.
    /// @param hook The hook the tokenId belongs to.
    /// @param tokenId The ID of the staker token to calculate for.
    /// @param token The reward token to check.
    /// @return tokenAmount The total uncollected amount (vesting + vested-but-uncollected).
    function claimedFor(
        address hook,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        override
        returns (uint256 tokenAmount)
    {
        tokenAmount = _unclaimedVestingAmountOf({hook: hook, groupId: 0, tokenId: tokenId, token: token});
    }

    /// @notice Calculate the total uncollected (vesting + vested-but-uncollected) amount for a staker token ID in a
    /// tier-scoped group.
    /// @param hook The hook the tokenId belongs to.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenId The ID of the staker token to calculate for.
    /// @param token The reward token to check.
    /// @return tokenAmount The total uncollected amount (vesting + vested-but-uncollected).
    function claimedFor(
        address hook,
        uint256[] calldata tierIds,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        override
        returns (uint256 tokenAmount)
    {
        tokenAmount =
            _unclaimedVestingAmountOf({hook: hook, groupId: _groupIdFor(tierIds), tokenId: tokenId, token: token});
    }

    /// @notice Calculate how much of a reward token is currently unlocked and ready to be collected for a given
    /// staker token ID. Only includes the vested portion — excludes amounts still locked in vesting.
    /// @param hook The hook the tokenId belongs to.
    /// @param tokenId The ID of the staker token to calculate for.
    /// @param token The reward token to check.
    /// @return tokenAmount The amount of tokens that can be collected right now via `collectVestedRewards`.
    function collectableFor(
        address hook,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        override
        returns (uint256 tokenAmount)
    {
        tokenAmount = _collectableFor({hook: hook, groupId: 0, tokenId: tokenId, token: token});
    }

    /// @notice Calculate how much of a reward token is currently unlocked and ready to be collected for a given
    /// staker token ID in a tier-scoped group.
    /// @param hook The hook the tokenId belongs to.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenId The ID of the staker token to calculate for.
    /// @param token The reward token to check.
    /// @return tokenAmount The amount of tokens that can be collected right now via `collectVestedRewards`.
    function collectableFor(
        address hook,
        uint256[] calldata tierIds,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        override
        returns (uint256 tokenAmount)
    {
        tokenAmount = _collectableFor({hook: hook, groupId: _groupIdFor(tierIds), tokenId: tokenId, token: token});
    }

    /// @notice The tier set that defines a reward group, recorded when the group is first funded.
    /// @param hook The hook the group belongs to.
    /// @param groupId The reward group.
    /// @return tierIds The strictly-increasing tier set defining the group (empty for the legacy group).
    function tierIdsOf(address hook, uint256 groupId) external view override returns (uint256[] memory tierIds) {
        tierIds = _tierIdsOfGroup[hook][groupId];
    }

    /// @notice The vesting position collateralized by a Revnet loan.
    /// @param loanId The Revnet loan NFT ID.
    function vestingLoanOf(uint256 loanId) external view override returns (JBVestingLoan memory) {
        return _vestingLoanOf[loanId];
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The number of the current round.
    function currentRound() public view override returns (uint256) {
        return (block.timestamp - STARTING_TIMESTAMP) / ROUND_DURATION;
    }

    /// @notice The timestamp at which a round started.
    /// @param round The round to get the start timestamp of.
    function roundStartTimestamp(uint256 round) public view override returns (uint256) {
        return STARTING_TIMESTAMP + ROUND_DURATION * round;
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Begin vesting any unclaimed past reward rounds, then collect everything that has since unlocked and
    /// transfer it to the beneficiary — so callers don't need to separately call `beginVesting`.
    /// @dev The model-specific per-round claim math and the authorization check live in the `_claimPastRewards`
    /// and `_requireCanClaimTokenIds` hooks each concrete distributor implements.
    /// @param hook The hook whose stakers are collecting.
    /// @param tokenIds The IDs of the tokens to collect for (caller must be authorized for all of them).
    /// @param tokens The reward tokens to collect vested amounts of.
    /// @param beneficiary The recipient of the collected tokens.
    function collectVestedRewards(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        public
        virtual
        override
    {
        _collectVestedRewards({
            hook: hook,
            groupId: 0,
            tokenIds: tokenIds,
            tokens: tokens,
            beneficiary: beneficiary
        });
    }

    /// @notice Begin vesting then collect everything unlocked for a tier-scoped reward group.
    /// @param hook The hook whose stakers are collecting.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenIds The IDs of the tokens to collect for (caller must be authorized for all of them).
    /// @param tokens The reward tokens to collect vested amounts of.
    /// @param beneficiary The recipient of the collected tokens.
    function collectVestedRewards(
        address hook,
        uint256[] calldata tierIds,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        public
        virtual
        override
    {
        _collectVestedRewards({
            hook: hook,
            groupId: _groupIdFor(tierIds),
            tokenIds: tokenIds,
            tokens: tokens,
            beneficiary: beneficiary
        });
    }

    /// @notice Borrow from a revnet using one token ID's uncollected vesting rewards as collateral.
    /// @dev The distributor keeps custody of the loan NFT. Collection is blocked until repayment restores the
    /// collateral to the original vesting schedule.
    /// @param hook The hook whose staker is borrowing against vesting rewards.
    /// @param tokenIds The single token ID to borrow against.
    /// @param tokens The single revnet reward token to collateralize.
    /// @param sourceToken The token to borrow from the revnet.
    /// @param minBorrowAmount The minimum amount to borrow, denominated in `sourceToken`.
    /// @param prepaidFeePercent The fee percent to charge upfront.
    /// @param beneficiary The recipient of the borrowed funds.
    /// @return loanId The Revnet loan NFT ID held by this distributor.
    /// @return collateralCount The amount of vesting rewards used as collateral.
    function borrowAgainstVesting(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address sourceToken,
        uint256 minBorrowAmount,
        uint256 prepaidFeePercent,
        address payable beneficiary
    )
        public
        virtual
        override
        returns (uint256 loanId, uint256 collateralCount)
    {
        (loanId, collateralCount) = _borrowAgainstVestingFor({
            hook: hook,
            groupId: 0,
            tokenIds: tokenIds,
            tokens: tokens,
            sourceToken: sourceToken,
            minBorrowAmount: minBorrowAmount,
            prepaidFeePercent: prepaidFeePercent,
            beneficiary: beneficiary
        });
    }

    /// @notice Borrow against one token ID's uncollected vesting rewards in a tier-scoped group.
    /// @param hook The hook whose staker is borrowing against vesting rewards.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenIds The single token ID to borrow against.
    /// @param tokens The single revnet reward token to collateralize.
    /// @param sourceToken The token to borrow from the revnet.
    /// @param minBorrowAmount The minimum amount to borrow, denominated in `sourceToken`.
    /// @param prepaidFeePercent The fee percent to charge upfront.
    /// @param beneficiary The recipient of the borrowed funds.
    /// @return loanId The Revnet loan NFT ID held by this distributor.
    /// @return collateralCount The amount of vesting rewards used as collateral.
    function borrowAgainstVesting(
        address hook,
        uint256[] calldata tierIds,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address sourceToken,
        uint256 minBorrowAmount,
        uint256 prepaidFeePercent,
        address payable beneficiary
    )
        public
        virtual
        override
        returns (uint256 loanId, uint256 collateralCount)
    {
        (loanId, collateralCount) = _borrowAgainstVestingFor({
            hook: hook,
            groupId: _groupIdFor(tierIds),
            tokenIds: tokenIds,
            tokens: tokens,
            sourceToken: sourceToken,
            minBorrowAmount: minBorrowAmount,
            prepaidFeePercent: prepaidFeePercent,
            beneficiary: beneficiary
        });
    }

    /// @notice Repay a distributor-held Revnet loan and restore its collateral to the original vesting schedule.
    /// @param loanId The Revnet loan NFT ID to repay.
    /// @param maxRepayBorrowAmount The maximum source-token amount the caller is willing to repay.
    /// @return paidOffLoanId The paid-off loan ID returned by Revnet loans.
    function repayVestingLoan(
        uint256 loanId,
        uint256 maxRepayBorrowAmount
    )
        public
        payable
        virtual
        override
        returns (uint256 paidOffLoanId)
    {
        // Do not let reward-token callbacks mutate claim accounting during an inbound transfer.
        _requireNotAcceptingToken();

        // Load the vesting position that this distributor locked when it opened the loan.
        JBVestingLoan memory vestingLoan = _vestingLoanOf[loanId];
        if (vestingLoan.hook == address(0)) revert JBDistributor_NoVestingLoan({loanId: loanId});

        // Use Revnet's current fee quote to determine the amount needed to repay this loan now.
        REVLoan memory loan = REV_LOANS.loanOf(loanId);
        uint256 repayBorrowAmount =
            uint256(loan.amount) + REV_LOANS.determineSourceFeeAmount({loan: loan, amount: loan.amount});

        // Respect the caller's maximum repayment limit.
        if (repayBorrowAmount > maxRepayBorrowAmount) {
            revert JBDistributor_InsufficientRepayAmount({
                amount: maxRepayBorrowAmount, requiredAmount: repayBorrowAmount
            });
        }

        // Measure any returned project tokens while excluding any source-token payment effects.
        uint256 rewardBalanceBefore = vestingLoan.token.balanceOf(address(this));

        // Repay through this distributor because it owns the loan NFT and must receive the returned collateral.
        paidOffLoanId = _repayLoanSource({
            loanId: loanId,
            loan: loan,
            repayBorrowAmount: repayBorrowAmount,
            collateralCount: vestingLoan.collateralCount
        });

        // Restore the collateral to inventory while preserving the original vesting data untouched.
        _restoreVestingCollateral({
            loanId: loanId,
            paidOffLoanId: paidOffLoanId,
            vestingLoan: vestingLoan,
            rewardBalanceBefore: rewardBalanceBefore,
            repayBorrowAmount: repayBorrowAmount
        });
    }

    /// @notice Write off a distributor-held Revnet loan after Revnet liquidation permanently destroys its collateral.
    /// @param loanId The liquidated Revnet loan NFT ID.
    /// @return collateralCount The amount of vesting rewards forfeited by liquidation.
    function writeOffLiquidatedVestingLoan(uint256 loanId) public virtual override returns (uint256 collateralCount) {
        // Do not let reward-token callbacks mutate claim accounting during an inbound transfer.
        _requireNotAcceptingToken();

        // Load the distributor-local position that was locked when the loan opened.
        JBVestingLoan memory vestingLoan = _vestingLoanOf[loanId];

        // Only distributor-tracked vesting loans can be written off.
        if (vestingLoan.hook == address(0)) revert JBDistributor_NoVestingLoan({loanId: loanId});

        // Revnet liquidation deletes the loan data. A live loan can still be repaid, so do not write it off.
        if (REV_LOANS.loanOf(loanId).createdAt != 0) revert JBDistributor_VestingLoanNotLiquidated({loanId: loanId});

        // Clear the stale distributor lock and forfeit only the collateralized vesting entries.
        collateralCount = _writeOffLiquidatedVestingLoan({loanId: loanId, vestingLoan: vestingLoan});
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Claim all past reward rounds for the given token IDs and reward tokens into fresh vesting entries.
    /// @param hook The hook whose stakers are claiming.
    /// @param groupId The reward group being claimed (0 = legacy all-tiers group).
    /// @param tokenIds The token IDs to claim for.
    /// @param tokens The reward tokens to claim.
    function _claimPastRewards(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens
    )
        internal
        virtual;

    /// @notice Revert unless the caller is authorized to claim each token ID.
    /// @param hook The hook whose token IDs are being checked.
    /// @param tokenIds The token IDs to check.
    function _requireCanClaimTokenIds(address hook, uint256[] calldata tokenIds) internal view virtual;

    /// @notice Shared begin-vesting logic across reward groups.
    /// @param hook The hook whose stakers are vesting.
    /// @param groupId The reward group (0 = legacy all-tiers group).
    /// @param tokenIds The staker token IDs to claim rewards for.
    /// @param tokens The reward tokens to begin vesting.
    function _beginVesting(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens
    )
        internal
    {
        // Reward accounting cannot change while an ERC-20 `transferFrom` is in progress.
        _requireNotAcceptingToken();

        // Revert if no token IDs are provided.
        if (tokenIds.length == 0) revert JBDistributor_EmptyTokenIds({tokenIdCount: tokenIds.length});

        // Only the entity authorized for these token IDs may start their vesting clock.
        _requireCanClaimTokenIds({hook: hook, tokenIds: tokenIds});

        // Materialize all unclaimed historical reward rounds into fresh vesting entries that start now.
        _claimPastRewards({hook: hook, groupId: groupId, tokenIds: tokenIds, tokens: tokens});
    }

    /// @notice Shared begin-vesting-then-collect logic across reward groups.
    /// @param hook The hook whose stakers are collecting.
    /// @param groupId The reward group (0 = legacy all-tiers group).
    /// @param tokenIds The token IDs to collect for.
    /// @param tokens The reward tokens to collect.
    /// @param beneficiary The recipient of the collected tokens.
    function _collectVestedRewards(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        internal
    {
        // Collections transfer reward tokens out; block them mid inbound transfer.
        _requireNotAcceptingToken();

        // Revert if no token IDs are provided.
        if (tokenIds.length == 0) revert JBDistributor_EmptyTokenIds({tokenIdCount: tokenIds.length});

        // Only the entity authorized for these token IDs may materialize and collect their rewards.
        _requireCanClaimTokenIds({hook: hook, tokenIds: tokenIds});

        // Before collecting, bring the token IDs current by starting vesting for any past reward rounds.
        _claimPastRewards({hook: hook, groupId: groupId, tokenIds: tokenIds, tokens: tokens});

        // Release whatever portion of existing vesting entries has unlocked by this round.
        _unlockRewards({
            hook: hook,
            groupId: groupId,
            tokenIds: tokenIds,
            tokens: tokens,
            beneficiary: beneficiary,
            ownerClaim: true
        });
    }

    /// @notice Shared forfeiture-release logic across reward groups.
    /// @param hook The hook whose tokens were burned.
    /// @param groupId The reward group (0 = legacy all-tiers group).
    /// @param tokenIds The IDs of the burned tokens.
    /// @param tokens The reward tokens to recycle.
    /// @param beneficiary Unused for forfeiture. Kept for interface compatibility.
    function _releaseForfeitedRewards(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        internal
    {
        // Do not let reward-token callbacks mutate vesting state during inbound balance-delta accounting.
        _requireNotAcceptingToken();

        // Make sure that all staker token IDs are burned.
        for (uint256 i; i < tokenIds.length;) {
            if (!_tokenBurned({hook: hook, tokenId: tokenIds[i]})) {
                revert JBDistributor_NoAccess({hook: hook, tokenId: tokenIds[i], account: msg.sender});
            }
            unchecked {
                ++i;
            }
        }

        // Unlock the rewards and recycle the forfeited amount.
        _unlockRewards({
            hook: hook,
            groupId: groupId,
            tokenIds: tokenIds,
            tokens: tokens,
            beneficiary: beneficiary,
            ownerClaim: false
        });
    }

    /// @notice Shared expired-reward recycling logic across reward groups.
    /// @param hook The hook whose expired rewards should be recycled.
    /// @param groupId The reward group (0 = legacy all-tiers group).
    /// @param token The reward token to recycle.
    /// @param rounds The reward rounds to recycle.
    /// @return amount The total amount recycled.
    function _burnExpiredRewards(
        address hook,
        uint256 groupId,
        IERC20 token,
        uint256[] calldata rounds
    )
        internal
        returns (uint256 amount)
    {
        // Do not let reward-token callbacks recycle inventory during an inbound balance-delta measurement.
        _requireNotAcceptingToken();

        // Process every requested round independently so callers can batch keeper work.
        for (uint256 i; i < rounds.length;) {
            amount += _recycleExpiredRewardRound({hook: hook, groupId: groupId, token: token, round: rounds[i]});
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Shared borrow-against-vesting logic across reward groups.
    /// @param hook The hook whose staker is borrowing against vesting rewards.
    /// @param groupId The reward group (0 = legacy all-tiers group).
    /// @param tokenIds The single token ID to borrow against.
    /// @param tokens The single revnet reward token to collateralize.
    /// @param sourceToken The token to borrow from the revnet.
    /// @param minBorrowAmount The minimum amount to borrow, denominated in `sourceToken`.
    /// @param prepaidFeePercent The fee percent to charge upfront.
    /// @param beneficiary The recipient of the borrowed funds.
    /// @return loanId The Revnet loan NFT ID held by this distributor.
    /// @return collateralCount The amount of vesting rewards used as collateral.
    function _borrowAgainstVestingFor(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address sourceToken,
        uint256 minBorrowAmount,
        uint256 prepaidFeePercent,
        address payable beneficiary
    )
        internal
        returns (uint256 loanId, uint256 collateralCount)
    {
        // Do not let reward-token callbacks mutate claim accounting during an inbound transfer.
        _requireNotAcceptingToken();

        // Revert if no token IDs are provided.
        if (tokenIds.length == 0) revert JBDistributor_EmptyTokenIds({tokenIdCount: tokenIds.length});

        // One distributor-held Revnet loan tracks one token ID so one repayment restores one vesting schedule.
        if (tokenIds.length != 1) revert JBDistributor_UnexpectedTokenCount({tokenCount: tokenIds.length});

        // One loan collateralizes one revnet reward token.
        if (tokens.length != 1) revert JBDistributor_UnexpectedTokenCount({tokenCount: tokens.length});

        // Zero vesting means rewards are immediately collectible, so there is no locked position to borrow against.
        if (VESTING_ROUNDS == 0) revert JBDistributor_VestingLoansDisabled();

        // Revnet loan-backed collection is disabled unless a trusted loans contract was set at deployment.
        if (address(REV_LOANS) == address(0)) revert JBDistributor_RevnetLoansNotConfigured();

        // Make sure that all tokens can be claimed by this sender.
        _requireCanClaimTokenIds({hook: hook, tokenIds: tokenIds});

        // Bundle the remaining borrow parameters to keep the loan workflow readable and stack-safe.
        JBBorrowContext memory ctx = JBBorrowContext({
            hook: hook,
            groupId: groupId,
            tokenId: tokenIds[0],
            token: tokens[0],
            sourceToken: sourceToken,
            minBorrowAmount: minBorrowAmount,
            prepaidFeePercent: prepaidFeePercent,
            beneficiary: beneficiary,
            revnetId: _revnetIdOf(tokens[0])
        });

        // Open and track the distributor-owned loan.
        (loanId, collateralCount) = _borrowAgainstVesting({ctx: ctx, tokenIds: tokenIds, tokens: tokens});
    }

    /// @notice Derive the canonical group ID for a tier set. The empty set is the legacy all-tiers group (0).
    /// @param tierIds Strictly-increasing tier IDs; empty for the legacy group.
    /// @return groupId 0 for the legacy group, else `keccak256(abi.encode(tierIds))`.
    function _groupIdFor(uint256[] calldata tierIds) internal pure returns (uint256 groupId) {
        if (tierIds.length == 0) return 0;
        for (uint256 i = 1; i < tierIds.length;) {
            if (tierIds[i] <= tierIds[i - 1]) {
                revert JBDistributor_TierIdsNotIncreasing({previousTierId: tierIds[i - 1], tierId: tierIds[i]});
            }
            unchecked {
                ++i;
            }
        }
        groupId = uint256(keccak256(abi.encode(tierIds)));
    }

    /// @notice Open and track a distributor-held Revnet loan against one vesting position.
    /// @param ctx The borrow context.
    /// @param tokenIds The single token ID being collateralized.
    /// @param tokens The single reward token being collateralized.
    /// @return loanId The Revnet loan NFT ID held by this distributor.
    /// @return collateralCount The amount of vesting rewards used as collateral.
    function _borrowAgainstVesting(
        JBBorrowContext memory ctx,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens
    )
        internal
        returns (uint256 loanId, uint256 collateralCount)
    {
        // One vesting position cannot be collateralized by two outstanding loans.
        uint256 activeLoanId = activeVestingLoanIdOf[ctx.hook][ctx.groupId][ctx.tokenId][ctx.token];
        if (activeLoanId != 0) {
            revert JBDistributor_VestingLoanOutstanding({
                hook: ctx.hook, tokenId: ctx.tokenId, token: address(ctx.token), loanId: activeLoanId
            });
        }

        // Bring the claimant current before measuring collateral.
        _claimPastRewards({hook: ctx.hook, groupId: ctx.groupId, tokenIds: tokenIds, tokens: tokens});

        // Use the remaining uncollected vesting amount as collateral without advancing the vesting schedule.
        collateralCount =
            _unclaimedVestingAmountOf({hook: ctx.hook, groupId: ctx.groupId, tokenId: ctx.tokenId, token: ctx.token});

        // Remember the vesting-entry boundary so liquidation write-off cannot consume later rewards.
        uint48 vestingDataCount = _toUint48(vestingDataOf[ctx.hook][ctx.groupId][ctx.tokenId][ctx.token].length);

        // A zero-collateral loan would revert in Revnet, but this local error explains why.
        if (collateralCount == 0) {
            revert JBDistributor_NothingToBorrow({hook: ctx.hook, token: address(ctx.token)});
        }

        // The collateralized tokens leave the hook's distributable inventory.
        _balanceOf[ctx.hook][ctx.token] -= collateralCount;
        _accountedBalanceOf[ctx.token] -= collateralCount;
        totalLoanedVestingAmountOf[ctx.hook][ctx.token] += collateralCount;

        // Block same-position reentrancy before the loan contract burns collateral and returns the real loan ID.
        activeVestingLoanIdOf[ctx.hook][ctx.groupId][ctx.tokenId][ctx.token] = _PENDING_VESTING_LOAN_ID;

        // Open the Revnet loan with this distributor as the holder whose tokens are burned as collateral.
        loanId = _openVestingLoan({ctx: ctx, collateralCount: collateralCount});
        if (loanId == 0 || loanId == _PENDING_VESTING_LOAN_ID) {
            revert JBDistributor_InvalidVestingLoanId({loanId: loanId});
        }

        // Track the distributor-held loan so repayment can restore the same vesting position.
        activeVestingLoanIdOf[ctx.hook][ctx.groupId][ctx.tokenId][ctx.token] = loanId;
        _vestingLoanOf[loanId] = JBVestingLoan({
            hook: ctx.hook,
            groupId: ctx.groupId,
            tokenId: ctx.tokenId,
            token: ctx.token,
            vestingDataCount: vestingDataCount,
            collateralCount: collateralCount
        });

        _emitBorrowAgainstVesting({ctx: ctx, loanId: loanId, collateralCount: collateralCount});
    }

    /// @notice Emit the borrow event for a distributor-owned vesting loan.
    /// @param ctx The borrow context.
    /// @param loanId The Revnet loan NFT ID held by this distributor.
    /// @param collateralCount The amount of vesting rewards used as collateral.
    function _emitBorrowAgainstVesting(JBBorrowContext memory ctx, uint256 loanId, uint256 collateralCount) internal {
        emit BorrowAgainstVesting({
            hook: ctx.hook,
            tokenId: ctx.tokenId,
            token: ctx.token,
            loanId: loanId,
            revnetId: ctx.revnetId,
            collateralCount: collateralCount,
            sourceToken: ctx.sourceToken,
            minBorrowAmount: ctx.minBorrowAmount,
            prepaidFeePercent: ctx.prepaidFeePercent,
            beneficiary: ctx.beneficiary,
            caller: msg.sender
        });
    }

    /// @notice Open a Revnet loan against this distributor's vesting reward inventory.
    /// @param ctx The borrow context.
    /// @param collateralCount The amount of vesting rewards used as collateral.
    /// @return loanId The Revnet loan NFT ID held by this distributor.
    function _openVestingLoan(JBBorrowContext memory ctx, uint256 collateralCount) internal returns (uint256 loanId) {
        (loanId,) = REV_LOANS.borrowFrom({
            revnetId: ctx.revnetId,
            token: ctx.sourceToken,
            minBorrowAmount: ctx.minBorrowAmount,
            collateralCount: collateralCount,
            beneficiary: ctx.beneficiary,
            prepaidFeePercent: ctx.prepaidFeePercent,
            holder: address(this)
        });
    }

    /// @notice Repay a Revnet loan with the source token it borrowed.
    /// @param loanId The Revnet loan NFT ID to repay.
    /// @param loan The Revnet loan data.
    /// @param repayBorrowAmount The amount of source token needed to repay the loan.
    /// @param collateralCount The amount of collateral to return.
    /// @return paidOffLoanId The paid-off loan ID returned by Revnet loans.
    function _repayLoanSource(
        uint256 loanId,
        REVLoan memory loan,
        uint256 repayBorrowAmount,
        uint256 collateralCount
    )
        internal
        returns (uint256 paidOffLoanId)
    {
        JBSingleAllowance memory allowance;

        if (loan.sourceToken == JBConstants.NATIVE_TOKEN) {
            // Native repayments must provide enough ETH for the exact current payoff.
            if (msg.value < repayBorrowAmount) {
                revert JBDistributor_InsufficientRepayAmount({amount: msg.value, requiredAmount: repayBorrowAmount});
            }

            // Repay the loan and route returned collateral back to the distributor.
            (paidOffLoanId,) = REV_LOANS.repayLoan{value: repayBorrowAmount}({
                loanId: loanId,
                maxRepayBorrowAmount: repayBorrowAmount,
                collateralCountToReturn: collateralCount,
                beneficiary: payable(address(this)),
                allowance: allowance
            });

            // Return any native overpayment to the caller.
            uint256 refundAmount = msg.value - repayBorrowAmount;
            if (refundAmount != 0) {
                (bool success,) = msg.sender.call{value: refundAmount}("");
                if (!success) {
                    revert JBDistributor_NativeTransferFailed({beneficiary: msg.sender, amount: refundAmount});
                }
            }
        } else {
            // ERC-20 repayments must not carry native ETH.
            if (msg.value != 0) {
                revert JBDistributor_UnexpectedNativeValue({msgValue: msg.value, token: loan.sourceToken});
            }

            // Pull the exact current payoff from the caller. Existing distributor inventory must not cover a shortfall.
            IERC20 sourceToken = IERC20(loan.sourceToken);
            uint256 sourceBalanceBefore = sourceToken.balanceOf(address(this));
            sourceToken.safeTransferFrom({from: msg.sender, to: address(this), value: repayBorrowAmount});
            uint256 receivedAmount = sourceToken.balanceOf(address(this)) - sourceBalanceBefore;
            if (receivedAmount != repayBorrowAmount) {
                revert JBDistributor_UnexpectedRepayAmount({amount: receivedAmount, expectedAmount: repayBorrowAmount});
            }

            // Approve only the exact amount needed for this repayment.
            sourceToken.forceApprove({spender: address(REV_LOANS), value: repayBorrowAmount});

            // Repay the loan and route returned collateral back to the distributor.
            (paidOffLoanId,) = REV_LOANS.repayLoan({
                loanId: loanId,
                maxRepayBorrowAmount: repayBorrowAmount,
                collateralCountToReturn: collateralCount,
                beneficiary: payable(address(this)),
                allowance: allowance
            });

            // Clear the temporary allowance for tokens that require explicit reset.
            sourceToken.forceApprove({spender: address(REV_LOANS), value: 0});
        }
    }

    /// @notice Restore repaid loan collateral to distributor inventory without changing vesting entries.
    /// @param loanId The Revnet loan NFT ID that was repaid.
    /// @param paidOffLoanId The paid-off loan ID returned by Revnet loans.
    /// @param vestingLoan The vesting position that was collateralized.
    /// @param rewardBalanceBefore The reward token balance before repayment.
    /// @param repayBorrowAmount The amount repaid in the loan's source token.
    function _restoreVestingCollateral(
        uint256 loanId,
        uint256 paidOffLoanId,
        JBVestingLoan memory vestingLoan,
        uint256 rewardBalanceBefore,
        uint256 repayBorrowAmount
    )
        internal
    {
        // Measure the returned collateral and any same-token source-fee overflow.
        uint256 rewardBalanceAfter = vestingLoan.token.balanceOf(address(this));
        uint256 restoredAmount = rewardBalanceAfter > rewardBalanceBefore ? rewardBalanceAfter - rewardBalanceBefore : 0;

        // Full repayment must return at least the collateral that was removed from inventory.
        if (restoredAmount < vestingLoan.collateralCount) {
            revert JBDistributor_InsufficientRepaidCollateral({
                expectedAmount: vestingLoan.collateralCount, actualAmount: restoredAmount
            });
        }

        // Put the collateral back into the hook's tracked inventory.
        _balanceOf[vestingLoan.hook][vestingLoan.token] += vestingLoan.collateralCount;
        _accountedBalanceOf[vestingLoan.token] += vestingLoan.collateralCount;
        totalLoanedVestingAmountOf[vestingLoan.hook][vestingLoan.token] -= vestingLoan.collateralCount;

        // Clear the lock that prevented this position from being collected while collateralized.
        delete activeVestingLoanIdOf[vestingLoan.hook][vestingLoan.groupId][vestingLoan.tokenId][vestingLoan.token];
        delete _vestingLoanOf[loanId];

        // Return any excess reward tokens created during source-fee payment to the repayer.
        uint256 excessRewardAmount = restoredAmount - vestingLoan.collateralCount;
        if (excessRewardAmount != 0) {
            vestingLoan.token.safeTransfer({to: msg.sender, value: excessRewardAmount});
        }

        emit RepayVestingLoan({
            loanId: loanId,
            paidOffLoanId: paidOffLoanId,
            token: vestingLoan.token,
            collateralCount: vestingLoan.collateralCount,
            repayBorrowAmount: repayBorrowAmount,
            caller: msg.sender
        });
    }

    /// @notice Clear a stale vesting-loan lock after liquidation permanently destroys the collateral.
    /// @param loanId The liquidated Revnet loan NFT ID.
    /// @param vestingLoan The distributor-local vesting position that backed the loan.
    /// @return collateralCount The amount of vesting rewards forfeited by liquidation.
    function _writeOffLiquidatedVestingLoan(
        uint256 loanId,
        JBVestingLoan memory vestingLoan
    )
        internal
        returns (uint256 collateralCount)
    {
        // Cache the collateral amount because it is used for accounting and the event.
        collateralCount = vestingLoan.collateralCount;

        // Load the vesting entries for the token ID whose rewards were collateralized.
        JBVestingData[] storage vestings =
            vestingDataOf[vestingLoan.hook][vestingLoan.groupId][vestingLoan.tokenId][vestingLoan.token];

        // Start at the first unexhausted vesting entry.
        uint256 vestedIndex =
            latestVestedIndexOf[vestingLoan.hook][vestingLoan.groupId][vestingLoan.tokenId][vestingLoan.token];

        // Stop at the boundary recorded when the loan opened, preserving newer vesting entries.
        uint256 vestingDataCount = vestingLoan.vestingDataCount;

        // Mark each collateralized entry fully claimed because Revnet liquidation destroyed its backing tokens.
        while (vestedIndex < vestingDataCount) {
            vestings[vestedIndex].shareClaimed = MAX_SHARE;

            unchecked {
                // Safe because the loop is bounded by the recorded vesting-entry count.
                ++vestedIndex;
            }
        }

        // Skip over the written-off vesting entries without ever moving the cursor backwards.
        latestVestedIndexOf[vestingLoan.hook][vestingLoan.groupId][vestingLoan.tokenId][vestingLoan.token] =
            vestedIndex;

        // Remove the liquidated collateral from the amount still considered vesting.
        totalVestingAmountOf[vestingLoan.hook][vestingLoan.token] -= collateralCount;

        // Remove the liquidated collateral from the loaned-vesting inventory.
        totalLoanedVestingAmountOf[vestingLoan.hook][vestingLoan.token] -= collateralCount;

        // Clear the active loan lock for this token ID and reward token.
        delete activeVestingLoanIdOf[vestingLoan.hook][vestingLoan.groupId][vestingLoan.tokenId][vestingLoan.token];

        // Clear the loan metadata so it cannot be written off or repaid again.
        delete _vestingLoanOf[loanId];

        emit LiquidatedVestingLoanWrittenOff({
            hook: vestingLoan.hook,
            tokenId: vestingLoan.tokenId,
            token: vestingLoan.token,
            loanId: loanId,
            collateralCount: collateralCount,
            caller: msg.sender
        });
    }

    /// @notice Accepts an ERC-20 funding transfer and returns the actual balance delta.
    /// @param token The ERC-20 token to accept.
    /// @param from The address to pull tokens from.
    /// @param amount The nominal amount to pull.
    /// @return acceptedAmount The actual amount received.
    function _acceptErc20FundsFrom(
        IERC20 token,
        address from,
        uint256 amount
    )
        internal
        returns (uint256 acceptedAmount)
    {
        // Arm the scoped guard before any token call, including `balanceOf`, because reward tokens are arbitrary and
        // an upgradeable or adversarial token can reenter from either the snapshot or transfer path.
        address tokenBeingAccepted = _acceptingToken;
        if (tokenBeingAccepted != address(0)) revert JBDistributor_ReentrantTokenTransfer(tokenBeingAccepted);
        _acceptingToken = address(token);

        // Snapshot this contract's token balance after the guard is armed so fee-on-transfer tokens are credited by the
        // actual amount received instead of the caller-provided nominal `amount`.
        uint256 balanceBefore = token.balanceOf(address(this));

        // Pull the nominal amount from the funder; SafeERC20 handles tokens that do not return a boolean.
        token.safeTransferFrom({from: from, to: address(this), value: amount});

        // Credit only the balance delta. This supports fee-on-transfer tokens and ignores any overstatement in
        // `amount`.
        acceptedAmount = token.balanceOf(address(this)) - balanceBefore;

        // Close the transfer window after the token balance has been measured.
        _acceptingToken = address(0);
    }

    /// @notice Accept funds and assign them to this round's reward ledger.
    /// @param hook The stake source whose stakers receive the rewards.
    /// @param groupId The reward group being funded (0 = legacy all-tiers group).
    /// @param tierIds The tier set defining the group; recorded on the group's first funding.
    /// @param token The reward token being funded.
    /// @param amount The nominal amount to fund.
    function _fund(address hook, uint256 groupId, uint256[] memory tierIds, IERC20 token, uint256 amount) internal {
        // Record the tier set the first time a tier-scoped group is funded, so the stake math can scope it later.
        if (groupId != 0 && _tierIdsOfGroup[hook][groupId].length == 0) {
            _tierIdsOfGroup[hook][groupId] = tierIds;
        }

        // Native funding is measured by msg.value, not the caller-provided amount.
        if (address(token) == JBConstants.NATIVE_TOKEN) {
            amount = msg.value;
        } else {
            // ERC-20 funding must not carry native ETH.
            if (msg.value != 0) {
                revert JBDistributor_UnexpectedNativeValue({msgValue: msg.value, token: address(token)});
            }

            // ERC-20 funding is measured by balance delta so fee-on-transfer tokens are accounted correctly.
            amount = _acceptErc20FundsFrom({token: token, from: msg.sender, amount: amount});
        }

        // Store the accepted amount in this round's historical reward ledger.
        _recordRewardFunding({hook: hook, groupId: groupId, token: token, amount: amount});
    }

    /// @notice Record accepted funding as the current round's reward pot.
    /// @param hook The stake source whose stakers receive the rewards.
    /// @param groupId The reward group (0 = legacy all-tiers group).
    /// @param token The reward token.
    /// @param amount The accepted funding amount.
    function _recordRewardFunding(address hook, uint256 groupId, IERC20 token, uint256 amount) internal {
        // Zero-value transfers do not create reward rounds or alter tracked balances.
        if (amount == 0) return;

        // Add the accepted amount to the current reward ledger.
        _recordRewardRound({hook: hook, groupId: groupId, token: token, amount: amount});

        // Keep the base distributor's balance accounting in sync for collection and conservation checks. Balances
        // are tracked per (hook, token) across all groups because they share one token custody pool.
        _balanceOf[hook][token] += amount;
        _accountedBalanceOf[token] += amount;
    }

    /// @notice Record rewards as the current round's claimable historical reward pot.
    /// @param hook The stake source whose stakers receive the rewards.
    /// @param groupId The reward group (0 = legacy all-tiers group).
    /// @param token The reward token.
    /// @param amount The amount to add to the current reward round.
    function _recordRewardRound(address hook, uint256 groupId, IERC20 token, uint256 amount) internal {
        // Zero-value rewards do not create reward rounds.
        if (amount == 0) return;

        // Rewards belong to the round in progress when they enter the ledger.
        uint256 round = currentRound();

        // Load the current round's ledger entry for this hook, group, and reward token.
        JBRewardRoundData storage rewardRound = rewardRoundOf[hook][groupId][token][round];

        // Every reward round in this contract uses the same immutable claim duration.
        uint48 claimDeadline = _claimDeadlineFor(round);

        // First value in a round locks that round's snapshot block and total stake.
        if (rewardRound.amount == 0) {
            // Record the exact historical block used for all stake lookups in this round.
            uint256 snapshotBlock = _ensureSnapshotBlockFor(round);

            // Store the snapshot block in the packed uint48 field.
            rewardRound.snapshotBlock = _toUint48(snapshotBlock);

            // Store the packed claim deadline fixed for this distributor.
            rewardRound.claimDeadline = claimDeadline;

            // Store the packed total stake that shares this group's round reward pot.
            rewardRound.totalStake =
                _toUint208(_totalStake({hook: hook, groupId: groupId, blockNumber: snapshotBlock}));
        }

        // Multiple additions in the same round share the same snapshot and reward pot.
        rewardRound.amount = _toUint208(uint256(rewardRound.amount) + amount);
    }

    /// @notice Recycle one expired reward round's unclaimed inventory into the current reward round.
    /// @param hook The hook whose expired rewards should be recycled.
    /// @param groupId The reward group (0 = legacy all-tiers group).
    /// @param token The reward token to recycle.
    /// @param round The reward round to recycle.
    /// @return recycleAmount The amount recycled.
    function _recycleExpiredRewardRound(
        address hook,
        uint256 groupId,
        IERC20 token,
        uint256 round
    )
        internal
        returns (uint256 recycleAmount)
    {
        // Load the reward round once so expiry, claimed amount, and funded amount stay in sync.
        JBRewardRoundData storage rewardRound = rewardRoundOf[hook][groupId][token][round];

        // Ignore rounds that either never expire or have not reached their deadline yet.
        if (!_rewardRoundExpired(rewardRound)) return 0;

        // If prior claims have already materialized the whole round, there is nothing left to recycle.
        if (rewardRound.claimedAmount >= rewardRound.amount) return 0;

        // Recycle only the unclaimed remainder, preserving amounts that already started vesting.
        recycleAmount = uint256(rewardRound.amount) - uint256(rewardRound.claimedAmount);

        // Mark the whole round settled before writing the recycled amount into a fresh round.
        rewardRound.claimedAmount = rewardRound.amount;

        // Keep the inventory in the distributor and give the current staker set a new claimable round.
        uint256 recycledToRound = currentRound();
        _recordRewardRound({hook: hook, groupId: groupId, token: token, amount: recycleAmount});

        // Surface the permissionless recycle for off-chain accounting.
        emit ExpiredRewardsRecycled({
            hook: hook,
            fromRound: round,
            toRound: recycledToRound,
            token: token,
            amount: recycleAmount,
            caller: msg.sender
        });
    }

    /// @notice Resolve the revnet project ID for a reward token.
    /// @param token The reward token to resolve.
    /// @return revnetId The token's revnet project ID.
    function _revnetIdOf(IERC20 token) internal view returns (uint256 revnetId) {
        // The reward token must be registered as a JB project token.
        revnetId = CONTROLLER.TOKENS().projectIdOf({token: IJBToken(address(token))});

        // The project must be owned by the configured REVOwner.
        if (revnetId == 0 || CONTROLLER.PROJECTS().ownerOf(revnetId) != address(REV_OWNER)) {
            revert JBDistributor_NotRevnetRewardToken({token: address(token)});
        }
    }

    /// @notice Cast a reward-round value to uint208.
    /// @param value The value to cast.
    /// @return castValue The cast value.
    function _toUint208(uint256 value) internal pure returns (uint208 castValue) {
        if (value > type(uint208).max) revert JBDistributor_Uint208Overflow({value: value});
        // forge-lint: disable-next-line(unsafe-typecast)
        castValue = uint208(value);
    }

    /// @notice Cast a value to uint48.
    /// @param value The value to cast.
    /// @return castValue The cast value.
    function _toUint48(uint256 value) internal pure returns (uint48 castValue) {
        if (value > type(uint48).max) revert JBDistributor_Uint48Overflow({value: value});
        // forge-lint: disable-next-line(unsafe-typecast)
        castValue = uint48(value);
    }

    /// @notice Ensures that a snapshot block is recorded for the given round.
    /// @dev Uses `block.number - 1` because `IVotes.getPastVotes` requires a strictly past block.
    /// @param round The round to ensure a snapshot block for.
    function _ensureSnapshotBlock(uint256 round) internal {
        _ensureSnapshotBlockFor(round);
        // Eagerly lock the next round's snapshot to prevent first-caller manipulation.
        _ensureSnapshotBlockFor(round + 1);
    }

    /// @notice Ensures that a snapshot block is recorded for exactly the given round.
    /// @dev Token-distributor funding uses this to assign rewards to the funding round without also freezing the next
    /// round earlier than necessary.
    /// @param round The round to ensure a snapshot block for.
    /// @return snapshotBlock The snapshot block recorded for the round.
    function _ensureSnapshotBlockFor(uint256 round) internal returns (uint256 snapshotBlock) {
        snapshotBlock = roundSnapshotBlock[round];
        if (snapshotBlock == 0) {
            snapshotBlock = block.number - 1;
            roundSnapshotBlock[round] = snapshotBlock;
            emit RoundSnapshotRecorded({round: round, snapshotBlock: snapshotBlock, caller: msg.sender});
        }
    }

    /// @notice The deadline for a reward round using this distributor's immutable claim duration.
    /// @param round The reward round.
    /// @return claimDeadline The deadline timestamp. Zero means no expiration.
    function _claimDeadlineFor(uint256 round) internal view returns (uint48 claimDeadline) {
        // Zero duration keeps the round non-expiring and backward compatible with existing fund paths.
        if (CLAIM_DURATION == 0) return 0;

        // Start the window at the next round boundary, when the funded round first becomes claimable.
        claimDeadline = _toUint48(roundStartTimestamp(round + 1) + CLAIM_DURATION);
    }

    /// @notice Whether a reward round has passed its claim deadline.
    /// @param rewardRound The reward round data.
    /// @return expired True if unclaimed rewards can be recycled.
    function _rewardRoundExpired(JBRewardRoundData storage rewardRound) internal view returns (bool expired) {
        // Copy the packed deadline into memory so the zero check and timestamp compare use the same value.
        uint48 claimDeadline = rewardRound.claimDeadline;

        // A zero deadline never expires; non-zero deadlines expire at or after the configured timestamp.
        // forge-lint: disable-next-line(block-timestamp)
        expired = claimDeadline != 0 && block.timestamp >= claimDeadline;
    }

    /// @notice Unlocks rewards for the given token IDs and tokens, either for collection or forfeiture.
    /// @param hook The hook the tokens belong to.
    /// @param groupId The reward group (0 = legacy all-tiers group).
    /// @param tokenIds The IDs of the tokens to unlock rewards for.
    /// @param tokens The addresses of the tokens to unlock.
    /// @param beneficiary The recipient of the unlocked tokens.
    /// @param ownerClaim Whether this is a claim by the owner (true) or a forfeiture release (false).
    function _unlockRewards(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary,
        bool ownerClaim
    )
        internal
    {
        uint256 round = currentRound();

        // Loop through each token for which vested rewards are being collected.
        for (uint256 i; i < tokens.length;) {
            IERC20 token = tokens[i];

            // Process all token IDs for this reward token.
            uint256 totalTokenAmount =
                _unlockTokenIds({hook: hook, groupId: groupId, tokenIds: tokenIds, token: token, round: round});

            // Perform the transfer.
            if (totalTokenAmount != 0) {
                unchecked {
                    // Update the amount that is left vesting.
                    totalVestingAmountOf[hook][token] -= totalTokenAmount;
                }

                // If this claim is from the owner (or on behalf of the owner).
                if (ownerClaim) {
                    // Decrement the hook's balance and transfer tokens out.
                    _balanceOf[hook][token] -= totalTokenAmount;
                    _accountedBalanceOf[token] -= totalTokenAmount;

                    if (address(token) == JBConstants.NATIVE_TOKEN) {
                        (bool success,) = beneficiary.call{value: totalTokenAmount}("");
                        if (!success) {
                            revert JBDistributor_NativeTransferFailed({
                                beneficiary: beneficiary, amount: totalTokenAmount
                            });
                        }
                    } else {
                        token.safeTransfer({to: beneficiary, value: totalTokenAmount});
                    }
                } else {
                    // If forfeiture: keep inventory in the distributor and give the current staker set a fresh round.
                    _recordRewardRound({hook: hook, groupId: groupId, token: token, amount: totalTokenAmount});
                    emit ForfeitedRewardsRecycled({
                        hook: hook, round: round, token: token, amount: totalTokenAmount, caller: msg.sender
                    });
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Unlocks rewards for a set of token IDs for a single reward token.
    /// @param hook The hook the tokens belong to.
    /// @param groupId The reward group (0 = legacy all-tiers group).
    /// @param tokenIds The IDs of the tokens to unlock rewards for.
    /// @param token The reward token to unlock.
    /// @param round The current round.
    /// @return totalTokenAmount The total amount of reward tokens unlocked.
    function _unlockTokenIds(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20 token,
        uint256 round
    )
        internal
        returns (uint256 totalTokenAmount)
    {
        for (uint256 j; j < tokenIds.length;) {
            uint256 tokenId = tokenIds[j];

            // Loan collateral stays locked until repayment restores it to this distributor.
            _requireNoActiveVestingLoan({hook: hook, groupId: groupId, tokenId: tokenId, token: token});

            // Keep a reference to the latest vested index.
            uint256 vestedIndex = latestVestedIndexOf[hook][groupId][tokenId][token];

            // Keep a reference to the vesting data array.
            JBVestingData[] storage vestings = vestingDataOf[hook][groupId][tokenId][token];
            uint256 numberOfVestingRounds = vestings.length;

            // Keep a reference to a vested index that will be incremented.
            uint256 newLatestVestedIndex = vestedIndex;

            while (vestedIndex < numberOfVestingRounds) {
                // Keep a reference to the vested data being iterated on.
                JBVestingData memory vesting = vestings[vestedIndex];

                uint256 lockedShare = JBVestingMath.lockedShareOf({
                    releaseRound: vesting.releaseRound,
                    currentRound: round,
                    vestingRounds: VESTING_ROUNDS,
                    maxShare: MAX_SHARE
                });

                // Match `claimedFor`/`collectableFor` by using the difference between cumulative rounded claims.
                // Rounding each incremental share independently can underpay partial unlocks and leave
                // `totalVestingAmountOf` larger than the remaining claims.
                (uint256 claimAmount,) = JBVestingMath.newlyClaimableAmountOf({
                    amount: vesting.amount,
                    shareClaimed: vesting.shareClaimed,
                    lockedShare: lockedShare,
                    maxShare: MAX_SHARE
                });

                if (claimAmount != 0) {
                    // Persist the cumulative unlocked share, not just this round's delta, so later collections
                    // compare against the same rounded checkpoint that produced `claimAmount`.
                    vestings[vestedIndex].shareClaimed = MAX_SHARE - lockedShare;
                    totalTokenAmount += claimAmount;
                    emit Collected({
                        hook: hook,
                        tokenId: tokenId,
                        groupId: groupId,
                        token: token,
                        amount: claimAmount,
                        vestingReleaseRound: vesting.releaseRound,
                        caller: msg.sender
                    });
                }

                unchecked {
                    ++vestedIndex;

                    // Only advance the latest-vested index contiguously past fully exhausted entries.
                    // An entry is exhausted only when its entire share has been claimed (lockedShare == 0).
                    if (
                        lockedShare == 0 && vestings[vestedIndex - 1].shareClaimed == MAX_SHARE
                            && vestedIndex == newLatestVestedIndex + 1
                    ) {
                        ++newLatestVestedIndex;
                    }
                }
            }

            latestVestedIndexOf[hook][groupId][tokenId][token] = newLatestVestedIndex;

            unchecked {
                ++j;
            }
        }
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice The collectable (unlocked, uncollected) amount for a token ID in a specific reward group.
    /// @param hook The hook the tokenId belongs to.
    /// @param groupId The reward group (0 = legacy all-tiers group).
    /// @param tokenId The ID of the staker token to calculate for.
    /// @param token The reward token to check.
    /// @return tokenAmount The amount of tokens that can be collected right now.
    function _collectableFor(
        address hook,
        uint256 groupId,
        uint256 tokenId,
        IERC20 token
    )
        internal
        view
        returns (uint256 tokenAmount)
    {
        // A loan keeps this token ID's vesting rewards in collateral custody until the loan is repaid.
        if (activeVestingLoanIdOf[hook][groupId][tokenId][token] != 0) return 0;

        // The round that we are in right now.
        uint256 round = currentRound();

        // Keep a reference to the latest vested index.
        uint256 vestedIndex = latestVestedIndexOf[hook][groupId][tokenId][token];

        // Keep a reference to the vesting data array.
        JBVestingData[] storage vestings = vestingDataOf[hook][groupId][tokenId][token];
        uint256 numberOfVestingRounds = vestings.length;

        while (vestedIndex < numberOfVestingRounds) {
            uint256 lockedShare;

            // Keep a reference to the vested data being iterated on.
            JBVestingData memory vesting = vestings[vestedIndex];

            lockedShare = JBVestingMath.lockedShareOf({
                releaseRound: vesting.releaseRound,
                currentRound: round,
                vestingRounds: VESTING_ROUNDS,
                maxShare: MAX_SHARE
            });

            // Calculate the newly unlocked amount from cumulative shares rather than the incremental share delta.
            // Incremental floor rounding can otherwise underpay partial collections and leave dust stranded.
            (uint256 claimAmount,) = JBVestingMath.newlyClaimableAmountOf({
                amount: vesting.amount,
                shareClaimed: vesting.shareClaimed,
                lockedShare: lockedShare,
                maxShare: MAX_SHARE
            });
            tokenAmount += claimAmount;

            unchecked {
                ++vestedIndex;
            }
        }
    }

    /// @notice The remaining uncollected vesting amount for one token ID and reward token.
    /// @param hook The hook the token ID belongs to.
    /// @param groupId The reward group (0 = legacy all-tiers group).
    /// @param tokenId The token ID to check.
    /// @param token The reward token to check.
    /// @return tokenAmount The amount still locked or unlocked-but-uncollected.
    function _unclaimedVestingAmountOf(
        address hook,
        uint256 groupId,
        uint256 tokenId,
        IERC20 token
    )
        internal
        view
        returns (uint256 tokenAmount)
    {
        // Keep a reference to the latest fully vested index.
        uint256 vestedIndex = latestVestedIndexOf[hook][groupId][tokenId][token];

        // Keep a reference to the vesting data array.
        JBVestingData[] storage vestings = vestingDataOf[hook][groupId][tokenId][token];
        uint256 numberOfVestingRounds = vestings.length;

        while (vestedIndex < numberOfVestingRounds) {
            // Keep a reference to the vested data being iterated on.
            JBVestingData memory vesting = vestings[vestedIndex];

            // Use `original - alreadyPaid` to include rounding dust in the remaining amount.
            tokenAmount += JBVestingMath.unclaimedAmountOf({
                amount: vesting.amount, shareClaimed: vesting.shareClaimed, maxShare: MAX_SHARE
            });

            unchecked {
                ++vestedIndex;
            }
        }
    }

    /// @notice Check whether an account is authorized to collect vested rewards for the given token ID. For 721
    /// distributors this is ownership; for token distributors this is address-encoding match.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The ID of the token to check.
    /// @param account The account to check authorization for.
    /// @return canClaim True if the account can collect rewards for this token ID.
    function _canClaim(address hook, uint256 tokenId, address account) internal view virtual returns (bool canClaim);

    /// @notice Revert if called while an inbound ERC-20 transfer is being measured.
    /// @dev Reward tokens are arbitrary contracts. This guard prevents token callbacks from mutating distributor
    /// accounting midway through a balance-delta measurement.
    function _requireNotAcceptingToken() internal view {
        address token = _acceptingToken;
        if (token != address(0)) revert JBDistributor_ReentrantTokenTransfer(token);
    }

    /// @notice Revert if a token ID's vesting rewards are locked in a distributor-owned loan.
    /// @param hook The hook the token ID belongs to.
    /// @param groupId The reward group (0 = legacy all-tiers group).
    /// @param tokenId The token ID to check.
    /// @param token The reward token to check.
    function _requireNoActiveVestingLoan(address hook, uint256 groupId, uint256 tokenId, IERC20 token) internal view {
        uint256 loanId = activeVestingLoanIdOf[hook][groupId][tokenId][token];
        if (loanId != 0) {
            revert JBDistributor_VestingLoanOutstanding({
                hook: hook, tokenId: tokenId, token: address(token), loanId: loanId
            });
        }
    }

    /// @notice Check whether a staker token has been burned. Burned tokens are excluded from stake calculations,
    /// and their unlocked forfeited rewards can be recycled via `releaseForfeitedRewards`.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The token ID to check.
    /// @return tokenWasBurned True if the token has been burned.
    function _tokenBurned(address hook, uint256 tokenId) internal view virtual returns (bool tokenWasBurned);

    /// @notice The stake weight of a specific token ID, used to calculate its pro-rata share of distributions.
    /// For 721 distributors this is the tier's voting units; for token distributors this is delegated voting power.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The ID of the token to get the stake weight of.
    /// @return tokenStakeAmount The stake weight represented by this token ID.
    function _tokenStake(address hook, uint256 tokenId) internal view virtual returns (uint256 tokenStakeAmount);

    /// @notice The total stake sharing a group's round rewards at a given block. Used as the denominator when
    /// calculating each token ID's pro-rata share. For the legacy group (0) this is `getPastTotalSupply`; for a
    /// tier-scoped group this is the summed `getPastTierVotingUnits` over the group's tier set.
    /// @param hook The hook to get the total stake for.
    /// @param groupId The reward group (0 = legacy all-tiers group).
    /// @param blockNumber The block number to query (must be strictly in the past).
    /// @return totalStakedAmount The total stake at the given block.
    function _totalStake(
        address hook,
        uint256 groupId,
        uint256 blockNumber
    )
        internal
        view
        virtual
        returns (uint256 totalStakedAmount);
}
