// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBPermissioned} from "@bananapus/core-v6/src/interfaces/IJBPermissioned.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {IJBDistributor} from "./interfaces/IJBDistributor.sol";
import {IREVLoans} from "./interfaces/IREVLoans.sol";
import {JBVestingMath} from "./libraries/JBVestingMath.sol";
import {JBBorrowContext} from "./structs/JBBorrowContext.sol";
import {JBRevnetLoan} from "./structs/JBRevnetLoan.sol";
import {JBRewardRoundData} from "./structs/JBRewardRoundData.sol";
import {JBTokenSnapshotData} from "./structs/JBTokenSnapshotData.sol";
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

    /// @notice Thrown when there is nothing to distribute for a token in the current round.
    error JBDistributor_NothingToDistribute(address hook, address token, uint256 round);

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

    /// @notice Thrown when unexpected native ETH is sent with an ERC-20 operation.
    error JBDistributor_UnexpectedNativeValue(uint256 msgValue, address token);

    /// @notice Thrown when a function requires exactly one reward token.
    error JBDistributor_UnexpectedTokenCount(uint256 tokenCount);

    /// @notice Thrown when a token ID has an outstanding loan against its vesting rewards.
    error JBDistributor_VestingLoanOutstanding(address hook, uint256 tokenId, address token, uint256 loanId);

    /// @notice Thrown when rewards cannot be burned by the JB controller.
    error JBDistributor_TokenNotBurnable(address token);

    /// @notice Thrown when a value cannot fit in a uint208 reward-round field.
    error JBDistributor_Uint208Overflow(uint256 value);

    /// @notice Thrown when a value cannot fit in a uint48 reward-round field.
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

    /// @notice The JB controller used to burn expired or forfeited project-token rewards.
    IJBController public immutable override CONTROLLER;

    /// @notice The duration of each round, specified in seconds.
    uint256 public immutable override ROUND_DURATION;

    /// @notice The Revnet loans contract used to borrow against vested revnet rewards.
    IREVLoans public immutable override REV_LOANS;

    /// @notice The REVOwner contract that must own a reward token's project to enable loan-backed collection.
    address public immutable override REV_OWNER;

    /// @notice The starting timestamp of the distributor.
    uint256 public immutable override STARTING_TIMESTAMP;

    /// @notice The number of rounds until tokens are fully vested.
    uint256 public immutable override VESTING_ROUNDS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The active Revnet loan using one token ID's vesting rewards as collateral.
    /// @custom:param hook The hook the token ID belongs to.
    /// @custom:param tokenId The token ID whose vesting rewards are collateralized.
    /// @custom:param token The reward token used as loan collateral.
    mapping(address hook => mapping(uint256 tokenId => mapping(IERC20 token => uint256)))
        public
        override activeVestingLoanIdOf;

    /// @notice The index within `vestingDataOf` of the latest vest.
    /// @custom:param hook The hook the tokenId belongs to.
    /// @custom:param tokenId The ID of the token to which the vests belong.
    /// @custom:param token The address of the token vested.
    mapping(address hook => mapping(uint256 tokenId => mapping(IERC20 token => uint256))) public latestVestedIndexOf;

    /// @notice The block number recorded as the snapshot point for each round.
    /// @dev Set to `block.number - 1` on first interaction in a round, so that `IVotes.getPastVotes` works.
    mapping(uint256 round => uint256) public override roundSnapshotBlock;

    /// @notice Reward data assigned to each funding round.
    /// @custom:param hook The stake source whose stakers receive rewards.
    /// @custom:param token The reward token.
    /// @custom:param round The reward round.
    mapping(address hook => mapping(IERC20 token => mapping(uint256 round => JBRewardRoundData))) public rewardRoundOf;

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
    /// @custom:param tokenId The ID of the token to which the vests belong.
    /// @custom:param token The address of the token vested.
    mapping(address hook => mapping(uint256 tokenId => mapping(IERC20 token => JBVestingData[]))) public vestingDataOf;

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

    /// @notice The vesting position collateralized by a Revnet loan.
    /// @custom:param loanId The Revnet loan NFT ID.
    mapping(uint256 loanId => JBVestingLoan) internal _vestingLoanOf;

    /// @notice The snapshot data of the token information for each round.
    /// @custom:param hook The hook the snapshot is for.
    /// @custom:param token The address of the token claimed and vested.
    /// @custom:param round The round to which the data applies.
    mapping(address hook => mapping(IERC20 token => mapping(uint256 round => JBTokenSnapshotData snapshot))) internal
        _snapshotAtRoundOf;

    /// @notice Whether a snapshot has been taken for a given (hook, token, round).
    /// @dev Required because a snapshot can legitimately store `{balance: 0, vestingAmount: 0}`,
    /// so a zero balance is not a usable sentinel for "uninitialized".
    /// @custom:param hook The hook the snapshot is for.
    /// @custom:param token The address of the token claimed and vested.
    /// @custom:param round The round to which the data applies.
    mapping(address hook => mapping(IERC20 token => mapping(uint256 round => bool))) internal _snapshotInitializedFor;

    //*********************************************************************//
    // ------------------- transient stored properties ------------------- //
    //*********************************************************************//

    /// @notice The ERC-20 whose incoming balance delta is currently being measured.
    address transient _acceptingToken;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param controller The JB controller used to burn expired or forfeited project-token rewards.
    /// @param revLoans The Revnet loans contract used to borrow against vested revnet rewards.
    /// @param revOwner The REVOwner contract that must own revnet reward token projects.
    /// @param initialRoundDuration The duration of each round, specified in seconds.
    /// @param initialVestingRounds The number of rounds until tokens are fully vested.
    /// @param initialClaimDuration The number of seconds claimants have after each reward round becomes claimable.
    constructor(
        address controller,
        address revLoans,
        address revOwner,
        uint256 initialRoundDuration,
        uint256 initialVestingRounds,
        uint48 initialClaimDuration
    ) {
        if (initialRoundDuration == 0) {
            revert JBDistributor_InvalidRoundDuration({roundDuration: initialRoundDuration});
        }
        CLAIM_DURATION = initialClaimDuration;
        CONTROLLER = IJBController(controller);
        REV_LOANS = IREVLoans(revLoans);
        REV_OWNER = revOwner;
        STARTING_TIMESTAMP = block.timestamp;
        ROUND_DURATION = initialRoundDuration;
        VESTING_ROUNDS = initialVestingRounds;

        // Let the trusted Revnet loans contract burn this distributor's project-token rewards as collateral.
        if (revLoans != address(0)) {
            uint8[] memory permissionIds = new uint8[](1);
            permissionIds[0] = JBPermissionIds.BURN_TOKENS;
            IJBPermissioned(controller).PERMISSIONS()
                .setPermissionsFor({
                account: address(this),
                permissionsData: JBPermissionsData({operator: revLoans, projectId: 0, permissionIds: permissionIds})
            });
        }
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Snapshot the current round's distributable balance and begin vesting for the specified token IDs.
    /// Each token ID's share is proportional to its stake weight relative to the total stake at the snapshot block.
    /// Vesting completes after `VESTING_ROUNDS` rounds. Reverts if there's nothing to distribute.
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
        // Reward accounting cannot change while an ERC-20 `transferFrom` is in progress. A callback-capable reward
        // token could otherwise snapshot, vest, or collect against balances between `balanceBefore` and
        // `balanceAfter`, distorting the delta credited to the funder.
        _requireNotAcceptingToken();

        // Revert if no token IDs are provided.
        if (tokenIds.length == 0) revert JBDistributor_EmptyTokenIds({tokenIdCount: tokenIds.length});

        // Keep a reference to the current round.
        uint256 round = currentRound();

        // Ensure the snapshot block is recorded for this round.
        _ensureSnapshotBlock(round);

        // Keep a reference to the total staked amount at the snapshot block.
        uint256 totalStakeAmount = _totalStake({hook: hook, blockNumber: roundSnapshotBlock[round]});

        // Skip vesting when there are no stakers — funds carry over to the next round.
        if (totalStakeAmount == 0) return;

        // Loop through each token for which vesting is beginning.
        for (uint256 i; i < tokens.length;) {
            IERC20 token = tokens[i];

            // Take a snapshot of the token balance if it hasn't been taken already.
            JBTokenSnapshotData memory snapshot = _takeSnapshotOf({hook: hook, token: token});
            uint256 distributable = snapshot.balance - snapshot.vestingAmount;

            // Revert if there is nothing to distribute for this token.
            if (distributable == 0) {
                revert JBDistributor_NothingToDistribute({hook: hook, token: address(token), round: round});
            }

            // Vest each token ID and get the total amount vested.
            uint256 totalVestingAmount = _vestTokenIds({
                hook: hook,
                tokenIds: tokenIds,
                token: token,
                distributable: distributable,
                totalStakeAmount: totalStakeAmount,
                vestingReleaseRound: round + VESTING_ROUNDS
            });

            unchecked {
                // Store the updated total claimed amount now vesting.
                totalVestingAmountOf[hook][token] += totalVestingAmount;

                ++i;
            }
        }
    }

    /// @notice Directly fund the distributor for a specific hook by pulling tokens from the caller. An alternative
    /// to split-based funding — useful for one-off deposits or external reward sources.
    /// @dev For native ETH, send `msg.value` and pass `IERC20(JBConstants.NATIVE_TOKEN)` as the token. Uses balance
    /// delta to handle fee-on-transfer tokens correctly.
    /// @param hook The hook to fund (determines which staker pool receives the tokens).
    /// @param token The token to fund with.
    /// @param amount The amount to fund (ignored for native ETH — `msg.value` is used instead).
    function fund(address hook, IERC20 token, uint256 amount) external payable virtual override {
        _fund({hook: hook, token: token, amount: amount});
    }

    /// @notice Burn unclaimed rewards from expired reward rounds.
    /// @param hook The hook whose expired rewards should be burned.
    /// @param token The reward token to burn.
    /// @param rounds The reward rounds to burn.
    /// @return amount The total amount burned.
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
        // Do not let reward-token callbacks burn inventory during an inbound balance-delta measurement.
        _requireNotAcceptingToken();

        // Process every requested round independently so callers can batch keeper work.
        for (uint256 i; i < rounds.length;) {
            // Add this round's expired remainder to the batch total.
            amount += _burnExpiredRewardRound({hook: hook, token: token, round: rounds[i]});

            unchecked {
                // Safe because the loop is bounded by calldata length.
                ++i;
            }
        }
    }

    /// @notice Record the snapshot block for the current round (and eagerly for the next round). Callable by anyone —
    /// keepers or frontends can call this early in a round to lock the snapshot block before any claims occur.
    function poke() external override {
        _ensureSnapshotBlock(currentRound());
    }

    /// @notice Burn unlocked rewards tied to burned tokens. When an NFT is burned, its pending vesting entries become
    /// stranded — this function unlocks and burns them instead of sending them to the beneficiary. Anyone can call
    /// this for burned tokens.
    /// @param hook The hook whose tokens were burned.
    /// @param tokenIds The IDs of the burned tokens (reverts if any are not actually burned).
    /// @param tokens The reward tokens to release.
    /// @param beneficiary Unused for forfeiture — tokens are burned. Kept for interface compatibility.
    function releaseForfeitedRewards(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external
        override
    {
        // Do not let reward-token callbacks mutate vesting state during inbound balance-delta accounting.
        _requireNotAcceptingToken();

        // Make sure that all tokens are burned.
        for (uint256 i; i < tokenIds.length;) {
            if (!_tokenBurned({hook: hook, tokenId: tokenIds[i]})) {
                revert JBDistributor_NoAccess({hook: hook, tokenId: tokenIds[i], account: msg.sender});
            }
            unchecked {
                ++i;
            }
        }

        // Unlock the rewards and burn the forfeited amount.
        _unlockRewards({hook: hook, tokenIds: tokenIds, tokens: tokens, beneficiary: beneficiary, ownerClaim: false});
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
        tokenAmount = _unclaimedVestingAmountOf({hook: hook, tokenId: tokenId, token: token});
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
        // A loan keeps this token ID's vesting rewards in collateral custody until the loan is repaid.
        if (activeVestingLoanIdOf[hook][tokenId][token] != 0) return 0;

        // The round that we are in right now.
        uint256 round = currentRound();

        // Keep a reference to the latest vested index.
        uint256 vestedIndex = latestVestedIndexOf[hook][tokenId][token];

        // Keep a reference to the number of vesting rounds for the tokenId and token.
        uint256 numberOfVestingRounds = vestingDataOf[hook][tokenId][token].length;

        while (vestedIndex < numberOfVestingRounds) {
            uint256 lockedShare;

            // Keep a reference to the vested data being iterated on.
            JBVestingData memory vesting = vestingDataOf[hook][tokenId][token][vestedIndex];

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

    /// @notice The snapshot data of the token information for each round.
    /// @param hook The hook the snapshot is for.
    /// @param token The address of the token claimed and vested.
    /// @param round The round to which the data applies.
    function snapshotAtRoundOf(
        address hook,
        IERC20 token,
        uint256 round
    )
        external
        view
        override
        returns (JBTokenSnapshotData memory)
    {
        return _snapshotAtRoundOf[hook][token][round];
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

    /// @notice Collect tokens that have vested (partially or fully) and transfer them to the beneficiary. Also
    /// auto-vests for the current round if rewards haven't been claimed yet — so callers don't need to separately
    /// call `beginVesting`. Only the token owner (verified via `_canClaim`) can collect.
    /// @param hook The hook whose stakers are collecting.
    /// @param tokenIds The IDs of the tokens to collect for (caller must own all of them).
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
        // Collections transfer reward tokens out. If this runs inside the same reward token's inbound transfer, the
        // outgoing transfer can net against the incoming balance delta and strand the new funds unaccounted.
        _requireNotAcceptingToken();

        // Revert if no token IDs are provided.
        if (tokenIds.length == 0) revert JBDistributor_EmptyTokenIds({tokenIdCount: tokenIds.length});

        // Make sure that all tokens can be claimed by this sender.
        for (uint256 i; i < tokenIds.length;) {
            if (!_canClaim({hook: hook, tokenId: tokenIds[i], account: msg.sender})) {
                revert JBDistributor_NoAccess({hook: hook, tokenId: tokenIds[i], account: msg.sender});
            }
            unchecked {
                ++i;
            }
        }

        // --- Auto-vest for the current round ---
        uint256 round = currentRound();

        // Ensure the snapshot block is recorded for this round.
        _ensureSnapshotBlock(round);

        // Keep a reference to the total staked amount at the snapshot block.
        uint256 totalStakeAmount = _totalStake({hook: hook, blockNumber: roundSnapshotBlock[round]});

        // Loop through each token and auto-vest if there's something distributable.
        for (uint256 i; i < tokens.length;) {
            IERC20 token = tokens[i];

            // Take a snapshot of the token balance if it hasn't been taken already.
            JBTokenSnapshotData memory snapshot = _takeSnapshotOf({hook: hook, token: token});
            uint256 distributable = snapshot.balance - snapshot.vestingAmount;

            // Only auto-vest if there's something to distribute and there's stake.
            if (distributable > 0 && totalStakeAmount > 0) {
                uint256 totalVestingAmount = _vestTokenIds({
                    hook: hook,
                    tokenIds: tokenIds,
                    token: token,
                    distributable: distributable,
                    totalStakeAmount: totalStakeAmount,
                    vestingReleaseRound: round + VESTING_ROUNDS
                });

                unchecked {
                    totalVestingAmountOf[hook][token] += totalVestingAmount;
                }
            }

            unchecked {
                ++i;
            }
        }

        // Unlock the rewards and send them to the beneficiary.
        _unlockRewards({hook: hook, tokenIds: tokenIds, tokens: tokens, beneficiary: beneficiary, ownerClaim: true});
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
        // Do not let reward-token callbacks mutate claim accounting during an inbound transfer.
        _requireNotAcceptingToken();

        // Revert if no token IDs are provided.
        if (tokenIds.length == 0) revert JBDistributor_EmptyTokenIds({tokenIdCount: tokenIds.length});

        // One distributor-held Revnet loan tracks one token ID so one repayment restores one vesting schedule.
        if (tokenIds.length != 1) revert JBDistributor_UnexpectedTokenCount({tokenCount: tokenIds.length});

        // One loan collateralizes one revnet reward token.
        if (tokens.length != 1) revert JBDistributor_UnexpectedTokenCount({tokenCount: tokens.length});

        // Revnet loan-backed collection is disabled unless a trusted loans contract was set at deployment.
        if (address(REV_LOANS) == address(0)) revert JBDistributor_RevnetLoansNotConfigured();

        // Make sure that all tokens can be claimed by this sender.
        _requireCanClaimTokenIds({hook: hook, tokenIds: tokenIds});

        // Bundle the remaining borrow parameters to keep the loan workflow readable and stack-safe.
        JBBorrowContext memory ctx = JBBorrowContext({
            hook: hook,
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
        JBRevnetLoan memory loan = REV_LOANS.loanOf(loanId);
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

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Claim all past reward rounds for the given token IDs and reward tokens into fresh vesting entries.
    /// @param hook The hook whose stakers are claiming.
    /// @param tokenIds The token IDs to claim for.
    /// @param tokens The reward tokens to claim.
    function _claimPastRewards(address hook, uint256[] calldata tokenIds, IERC20[] calldata tokens) internal virtual;

    /// @notice Revert unless the caller is authorized to claim each token ID.
    /// @param hook The hook whose token IDs are being checked.
    /// @param tokenIds The token IDs to check.
    function _requireCanClaimTokenIds(address hook, uint256[] calldata tokenIds) internal view virtual;

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
        uint256 activeLoanId = activeVestingLoanIdOf[ctx.hook][ctx.tokenId][ctx.token];
        if (activeLoanId != 0) {
            revert JBDistributor_VestingLoanOutstanding({
                hook: ctx.hook, tokenId: ctx.tokenId, token: address(ctx.token), loanId: activeLoanId
            });
        }

        // Bring the claimant current before measuring collateral.
        _claimPastRewards({hook: ctx.hook, tokenIds: tokenIds, tokens: tokens});

        // Use the remaining uncollected vesting amount as collateral without advancing the vesting schedule.
        collateralCount = _unclaimedVestingAmountOf({hook: ctx.hook, tokenId: ctx.tokenId, token: ctx.token});

        // A zero-collateral loan would revert in Revnet, but this local error explains why.
        if (collateralCount == 0) {
            revert JBDistributor_NothingToBorrow({hook: ctx.hook, token: address(ctx.token)});
        }

        // The collateralized tokens leave the hook's distributable inventory.
        _balanceOf[ctx.hook][ctx.token] -= collateralCount;
        _accountedBalanceOf[ctx.token] -= collateralCount;
        totalLoanedVestingAmountOf[ctx.hook][ctx.token] += collateralCount;

        // Block same-position reentrancy before the loan contract burns collateral and returns the real loan ID.
        activeVestingLoanIdOf[ctx.hook][ctx.tokenId][ctx.token] = _PENDING_VESTING_LOAN_ID;

        // Open the Revnet loan with this distributor as the holder whose tokens are burned as collateral.
        loanId = _openVestingLoan({ctx: ctx, collateralCount: collateralCount});
        if (loanId == 0 || loanId == _PENDING_VESTING_LOAN_ID) {
            revert JBDistributor_InvalidVestingLoanId({loanId: loanId});
        }

        // Track the distributor-held loan so repayment can restore the same vesting position.
        activeVestingLoanIdOf[ctx.hook][ctx.tokenId][ctx.token] = loanId;
        _vestingLoanOf[loanId] =
            JBVestingLoan({hook: ctx.hook, tokenId: ctx.tokenId, token: ctx.token, collateralCount: collateralCount});

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
        JBRevnetLoan memory loan,
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

            // Pull the exact current payoff from the caller.
            IERC20 sourceToken = IERC20(loan.sourceToken);
            sourceToken.safeTransferFrom({from: msg.sender, to: address(this), value: repayBorrowAmount});

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
        delete activeVestingLoanIdOf[vestingLoan.hook][vestingLoan.tokenId][vestingLoan.token];
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
    /// @param token The reward token being funded.
    /// @param amount The nominal amount to fund.
    function _fund(address hook, IERC20 token, uint256 amount) internal {
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
        _recordRewardFunding({hook: hook, token: token, amount: amount});
    }

    /// @notice Record accepted funding as the current round's reward pot.
    /// @param hook The stake source whose stakers receive the rewards.
    /// @param token The reward token.
    /// @param amount The accepted funding amount.
    function _recordRewardFunding(address hook, IERC20 token, uint256 amount) internal {
        // Zero-value transfers do not create reward rounds or alter tracked balances.
        if (amount == 0) return;

        // Add the accepted amount to the current reward ledger.
        _recordRewardRound({hook: hook, token: token, amount: amount});

        // Keep the base distributor's balance accounting in sync for collection and conservation checks.
        _balanceOf[hook][token] += amount;
        _accountedBalanceOf[token] += amount;
    }

    /// @notice Record rewards as the current round's claimable historical reward pot.
    /// @param hook The stake source whose stakers receive the rewards.
    /// @param token The reward token.
    /// @param amount The amount to add to the current reward round.
    function _recordRewardRound(address hook, IERC20 token, uint256 amount) internal {
        // Zero-value rewards do not create reward rounds.
        if (amount == 0) return;

        // Rewards belong to the round in progress when they enter the ledger.
        uint256 round = currentRound();

        // Load the current round's ledger entry for this hook and reward token.
        JBRewardRoundData storage rewardRound = rewardRoundOf[hook][token][round];

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

            // Store the packed total stake that shares this round's reward pot.
            rewardRound.totalStake = _toUint208(_totalStake({hook: hook, blockNumber: snapshotBlock}));
        }

        // Multiple additions in the same round share the same snapshot and reward pot.
        rewardRound.amount = _toUint208(uint256(rewardRound.amount) + amount);
    }

    /// @notice Burn one expired reward round's unclaimed inventory.
    /// @param hook The hook whose expired rewards should be burned.
    /// @param token The reward token to burn.
    /// @param round The reward round to burn.
    /// @return burnAmount The amount burned.
    function _burnExpiredRewardRound(address hook, IERC20 token, uint256 round) internal returns (uint256 burnAmount) {
        // Load the reward round once so expiry, claimed amount, and funded amount stay in sync.
        JBRewardRoundData storage rewardRound = rewardRoundOf[hook][token][round];

        // Ignore rounds that either never expire or have not reached their deadline yet.
        if (!_rewardRoundExpired(rewardRound)) return 0;

        // If prior claims have already materialized the whole round, there is nothing left to burn.
        if (rewardRound.claimedAmount >= rewardRound.amount) return 0;

        // Burn only the unclaimed remainder, preserving amounts that already started vesting.
        burnAmount = uint256(rewardRound.amount) - uint256(rewardRound.claimedAmount);

        // Mark the whole round settled before transferring to close reentrancy-sensitive accounting.
        rewardRound.claimedAmount = rewardRound.amount;

        // Remove the expired remainder from distributor inventory and burn it through the JB controller.
        _burnRewardTokens({hook: hook, token: token, amount: burnAmount});

        // Surface the permissionless burn for off-chain accounting.
        emit ExpiredRewardsBurned({hook: hook, round: round, token: token, amount: burnAmount, caller: msg.sender});
    }

    /// @notice Burn reward inventory using the JB controller.
    /// @param hook The hook whose tracked balance is being burned.
    /// @param token The reward token to burn.
    /// @param amount The amount to burn.
    function _burnRewardTokens(address hook, IERC20 token, uint256 amount) internal {
        // No-op zero burns so callers can batch empty or already-settled rounds safely.
        if (amount == 0) return;

        // A missing controller means there is no burn authority for any reward token.
        if (address(CONTROLLER) == address(0)) revert JBDistributor_TokenNotBurnable({token: address(token)});

        // Only JB project tokens can be burned through `JBController.burnTokensOf`.
        uint256 projectId = CONTROLLER.TOKENS().projectIdOf({token: IJBToken(address(token))});

        // Revert instead of sending unsupported rewards to a burn address.
        if (projectId == 0) revert JBDistributor_TokenNotBurnable({token: address(token)});

        // Remove the burned amount from the hook's reward inventory.
        _balanceOf[hook][token] -= amount;

        // Remove the same amount from the global inventory tracked for this token.
        _accountedBalanceOf[token] -= amount;

        // Burn from this distributor's project-token balance or token credits.
        CONTROLLER.burnTokensOf({holder: address(this), projectId: projectId, tokenCount: amount, memo: ""});
    }

    /// @notice Resolve the revnet project ID for a reward token.
    /// @param token The reward token to resolve.
    /// @return revnetId The token's revnet project ID.
    function _revnetIdOf(IERC20 token) internal view returns (uint256 revnetId) {
        // The reward token must be registered as a JB project token.
        revnetId = CONTROLLER.TOKENS().projectIdOf({token: IJBToken(address(token))});

        // The project must be owned by the configured REVOwner.
        if (revnetId == 0 || CONTROLLER.PROJECTS().ownerOf(revnetId) != REV_OWNER) {
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

    /// @notice Cast a reward-round value to uint48.
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

    /// @notice Takes a snapshot of the token balance and vesting amount for the current round.
    /// @param hook The hook to take the snapshot for.
    /// @param token The token address to take a snapshot of.
    /// @return snapshot The snapshot data.
    function _takeSnapshotOf(address hook, IERC20 token) internal returns (JBTokenSnapshotData memory snapshot) {
        // Keep a reference to the current round.
        uint256 round = currentRound();

        // If a snapshot was already taken at this round, do not take a new one. The init flag must be used as the
        // sentinel: a zero balance is a valid snapshot value (round started with no funded balance), not a signal
        // to re-snapshot. Re-snapshotting would let mid-round deposits leak into the current round's allocation.
        if (_snapshotInitializedFor[hook][token][round]) {
            return _snapshotAtRoundOf[hook][token][round];
        }

        // Exclude collateralized vesting inventory because those tokens have been burned into distributor-held loans.
        uint256 vestingAmount = totalVestingAmountOf[hook][token] - totalLoanedVestingAmountOf[hook][token];

        // Take a snapshot using the hook's tracked balance.
        snapshot = JBTokenSnapshotData({balance: _balanceOf[hook][token], vestingAmount: vestingAmount});

        // Store the snapshot and mark it initialized.
        _snapshotAtRoundOf[hook][token][round] = snapshot;
        _snapshotInitializedFor[hook][token][round] = true;

        emit SnapshotCreated({
            hook: hook,
            round: round,
            token: token,
            balance: snapshot.balance,
            vestingAmount: snapshot.vestingAmount,
            caller: msg.sender
        });
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
    /// @return expired True if unclaimed rewards can be burned.
    function _rewardRoundExpired(JBRewardRoundData storage rewardRound) internal view returns (bool expired) {
        // Copy the packed deadline into memory so the zero check and timestamp compare use the same value.
        uint48 claimDeadline = rewardRound.claimDeadline;

        // A zero deadline never expires; non-zero deadlines expire at or after the configured timestamp.
        // forge-lint: disable-next-line(block-timestamp)
        expired = claimDeadline != 0 && block.timestamp >= claimDeadline;
    }

    /// @notice Unlocks rewards for the given token IDs and tokens, either for collection or forfeiture.
    /// @param hook The hook the tokens belong to.
    /// @param tokenIds The IDs of the tokens to unlock rewards for.
    /// @param tokens The addresses of the tokens to unlock.
    /// @param beneficiary The recipient of the unlocked tokens.
    /// @param ownerClaim Whether this is a claim by the owner (true) or a forfeiture release (false).
    function _unlockRewards(
        address hook,
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
            uint256 totalTokenAmount = _unlockTokenIds({hook: hook, tokenIds: tokenIds, token: token, round: round});

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
                    // If forfeiture: remove the unlocked amount from inventory and burn it through the JB controller.
                    _burnRewardTokens({hook: hook, token: token, amount: totalTokenAmount});
                }
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Unlocks rewards for a set of token IDs for a single reward token.
    /// @param hook The hook the tokens belong to.
    /// @param tokenIds The IDs of the tokens to unlock rewards for.
    /// @param token The reward token to unlock.
    /// @param round The current round.
    /// @return totalTokenAmount The total amount of reward tokens unlocked.
    function _unlockTokenIds(
        address hook,
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
            _requireNoActiveVestingLoan({hook: hook, tokenId: tokenId, token: token});

            // Keep a reference to the latest vested index.
            uint256 vestedIndex = latestVestedIndexOf[hook][tokenId][token];

            // Keep a reference to the vesting data array.
            JBVestingData[] storage vestings = vestingDataOf[hook][tokenId][token];
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

            latestVestedIndexOf[hook][tokenId][token] = newLatestVestedIndex;

            unchecked {
                ++j;
            }
        }
    }

    /// @notice Vests each token ID for a given reward token and returns the total amount vested.
    /// @dev Silently skips already-vested tokenIds instead of reverting, to support auto-vest.
    /// @param hook The hook whose stakers are vesting.
    /// @param tokenIds The IDs to claim rewards for.
    /// @param token The reward token.
    /// @param distributable The distributable amount for this round.
    /// @param totalStakeAmount The total stake amount.
    /// @param vestingReleaseRound The round at which vesting will be released.
    /// @return totalVestingAmount The total amount that began vesting.
    function _vestTokenIds(
        address hook,
        uint256[] calldata tokenIds,
        IERC20 token,
        uint256 distributable,
        uint256 totalStakeAmount,
        uint256 vestingReleaseRound
    )
        internal
        virtual
        returns (uint256 totalVestingAmount)
    {
        for (uint256 j; j < tokenIds.length;) {
            uint256 tokenId = tokenIds[j];

            // Skip burned tokens — they are excluded from _totalStake, so including them would overbook vesting.
            if (_tokenBurned({hook: hook, tokenId: tokenId})) {
                unchecked {
                    ++j;
                }
                continue;
            }

            // Keep a reference to the vesting data for this hook/tokenId/token.
            JBVestingData[] storage vestings = vestingDataOf[hook][tokenId][token];

            // Skip if this token has already been vested for this round (same releaseRound).
            uint256 numVesting = vestings.length;
            if (numVesting != 0 && vestings[numVesting - 1].releaseRound == vestingReleaseRound) {
                unchecked {
                    ++j;
                }
                continue;
            }

            // Keep a reference to the amount of tokens being claimed.
            uint256 tokenAmount = mulDiv({
                x: distributable, y: _tokenStake({hook: hook, tokenId: tokenId}), denominator: totalStakeAmount
            });

            // Skip zero-amount entries to prevent stalling latestVestedIndexOf advancement.
            if (tokenAmount == 0) {
                unchecked {
                    ++j;
                }
                continue;
            }

            // Add to the list of vesting data.
            vestings.push(JBVestingData({releaseRound: vestingReleaseRound, amount: tokenAmount, shareClaimed: 0}));

            emit Claimed({
                hook: hook,
                tokenId: tokenId,
                token: token,
                amount: tokenAmount,
                vestingReleaseRound: vestingReleaseRound,
                caller: msg.sender
            });

            unchecked {
                totalVestingAmount += tokenAmount;
                ++j;
            }
        }
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice The remaining uncollected vesting amount for one token ID and reward token.
    /// @param hook The hook the token ID belongs to.
    /// @param tokenId The token ID to check.
    /// @param token The reward token to check.
    /// @return tokenAmount The amount still locked or unlocked-but-uncollected.
    function _unclaimedVestingAmountOf(
        address hook,
        uint256 tokenId,
        IERC20 token
    )
        internal
        view
        returns (uint256 tokenAmount)
    {
        // Keep a reference to the latest fully vested index.
        uint256 vestedIndex = latestVestedIndexOf[hook][tokenId][token];

        // Keep a reference to the number of vesting entries for the token ID and token.
        uint256 numberOfVestingRounds = vestingDataOf[hook][tokenId][token].length;

        while (vestedIndex < numberOfVestingRounds) {
            // Keep a reference to the vested data being iterated on.
            JBVestingData memory vesting = vestingDataOf[hook][tokenId][token][vestedIndex];

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
    /// @param tokenId The token ID to check.
    /// @param token The reward token to check.
    function _requireNoActiveVestingLoan(address hook, uint256 tokenId, IERC20 token) internal view {
        uint256 loanId = activeVestingLoanIdOf[hook][tokenId][token];
        if (loanId != 0) {
            revert JBDistributor_VestingLoanOutstanding({
                hook: hook, tokenId: tokenId, token: address(token), loanId: loanId
            });
        }
    }

    /// @notice Check whether a staker token has been burned. Burned tokens are excluded from stake calculations
    /// and their unvested rewards can be released via `releaseForfeitedRewards`.
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

    /// @notice The total stake across all token IDs at a given block. Used as the denominator when calculating each
    /// token ID's pro-rata share. For 721 distributors this is `getPastTotalSupply` from the checkpoints module;
    /// for token distributors this is `getPastTotalSupply` from the IVotes token.
    /// @param hook The hook to get the total stake for.
    /// @param blockNumber The block number to query (must be strictly in the past).
    /// @return totalStakedAmount The total stake at the given block.
    function _totalStake(address hook, uint256 blockNumber) internal view virtual returns (uint256 totalStakedAmount);
}
