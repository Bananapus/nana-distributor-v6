// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";

import {JBVestingLoan} from "../structs/JBVestingLoan.sol";

/// @notice Interface for round-based reward distributors with linear vesting. Stakers claim their share of funded
/// reward rounds, and claimed amounts vest linearly over a configurable number of rounds.
/// Two implementations exist: `JBTokenDistributor` (IVotes token stakers) and `JB721Distributor` (NFT holders).
interface IJBDistributor {
    //*********************************************************************//
    // -------------------------------- events --------------------------- //
    //*********************************************************************//

    /// @notice Emitted when vesting revnet rewards are used as Revnet loan collateral.
    /// @param hook The hook whose token ID owns the vesting rewards.
    /// @param tokenId The token ID whose vesting rewards are collateralized.
    /// @param token The revnet reward token used as collateral.
    /// @param loanId The Revnet loan NFT ID held by this distributor.
    /// @param revnetId The revnet whose project token is collateralized.
    /// @param collateralCount The amount of vesting rewards used as collateral.
    /// @param sourceToken The token borrowed from the revnet.
    /// @param minBorrowAmount The minimum amount to borrow.
    /// @param prepaidFeePercent The prepaid fee percent used by the loan.
    /// @param beneficiary The recipient of the borrowed funds.
    /// @param caller The address that opened the loan.
    event BorrowAgainstVesting(
        address indexed hook,
        uint256 indexed tokenId,
        IERC20 indexed token,
        uint256 loanId,
        uint256 revnetId,
        uint256 collateralCount,
        address sourceToken,
        uint256 minBorrowAmount,
        uint256 prepaidFeePercent,
        address beneficiary,
        address caller
    );

    /// @notice Emitted when a staker begins vesting tokens.
    /// @param hook The hook whose stakers are vesting.
    /// @param tokenId The ID of the staked token that is claiming.
    /// @param token The address of the token to vest.
    /// @param amount The amount of tokens to vest.
    /// @param vestingReleaseRound The round at which the tokens will be fully released.
    /// @param caller The address that triggered the claim.
    event Claimed(
        address indexed hook,
        uint256 indexed tokenId,
        IERC20 token,
        uint256 amount,
        uint256 vestingReleaseRound,
        address caller
    );

    /// @notice Emitted when vested tokens are collected.
    /// @param hook The hook whose stakers are collecting.
    /// @param tokenId The ID of the staked token collecting.
    /// @param token The address of the token collected.
    /// @param amount The amount of tokens collected.
    /// @param vestingReleaseRound The round at which the tokens will be fully released.
    /// @param caller The address that triggered the collection.
    event Collected(
        address indexed hook,
        uint256 indexed tokenId,
        IERC20 token,
        uint256 amount,
        uint256 vestingReleaseRound,
        address caller
    );

    /// @notice Emitted when a snapshot block is first recorded for a round.
    /// @param round The round the snapshot block was recorded for.
    /// @param snapshotBlock The block number recorded as the snapshot point.
    /// @param caller The address that triggered the snapshot recording.
    event RoundSnapshotRecorded(uint256 indexed round, uint256 snapshotBlock, address caller);

    /// @notice Emitted when an expired reward round's unclaimed amount is recycled into a later reward round.
    /// @param hook The hook whose expired rewards were recycled.
    /// @param fromRound The expired reward round.
    /// @param toRound The reward round receiving the recycled rewards.
    /// @param token The reward token that was recycled.
    /// @param amount The unclaimed reward amount recycled.
    /// @param caller The address that triggered the recycle.
    event ExpiredRewardsRecycled(
        address indexed hook,
        uint256 indexed fromRound,
        uint256 indexed toRound,
        IERC20 token,
        uint256 amount,
        address caller
    );

    /// @notice Emitted when unlocked rewards from burned tokens are recycled into the current reward round.
    /// @param hook The hook whose forfeited rewards were recycled.
    /// @param round The reward round receiving the recycled rewards.
    /// @param token The reward token that was recycled.
    /// @param amount The forfeited reward amount recycled.
    /// @param caller The address that triggered the recycle.
    event ForfeitedRewardsRecycled(
        address indexed hook, uint256 indexed round, IERC20 indexed token, uint256 amount, address caller
    );

    /// @notice Emitted when a liquidated distributor-held Revnet loan is written off.
    /// @param hook The hook whose vesting rewards were collateralized.
    /// @param tokenId The token ID whose vesting rewards were collateralized.
    /// @param token The revnet reward token whose collateral was liquidated.
    /// @param loanId The liquidated Revnet loan NFT ID.
    /// @param collateralCount The amount of vesting rewards forfeited by liquidation.
    /// @param caller The address that triggered the write-off.
    event LiquidatedVestingLoanWrittenOff(
        address indexed hook,
        uint256 indexed tokenId,
        IERC20 indexed token,
        uint256 loanId,
        uint256 collateralCount,
        address caller
    );

    /// @notice Emitted when a distributor-held Revnet loan is repaid and its collateral resumes vesting.
    /// @param loanId The Revnet loan NFT ID that was repaid.
    /// @param paidOffLoanId The paid-off loan ID returned by Revnet loans.
    /// @param token The revnet reward token restored to vesting.
    /// @param collateralCount The amount of vesting rewards restored.
    /// @param repayBorrowAmount The amount repaid, denominated in the loan source token.
    /// @param caller The address that repaid the loan.
    event RepayVestingLoan(
        uint256 indexed loanId,
        uint256 indexed paidOffLoanId,
        IERC20 indexed token,
        uint256 collateralCount,
        uint256 repayBorrowAmount,
        address caller
    );

    //*********************************************************************//
    // ----------------------------- views ------------------------------- //
    //*********************************************************************//

    /// @notice The number of seconds after a reward round becomes claimable before unclaimed rewards expire.
    /// @dev A zero duration means reward rounds do not expire.
    function CLAIM_DURATION() external view returns (uint48);

    /// @notice The JB controller used for token registry lookups and revnet loan permissions.
    function CONTROLLER() external view returns (IJBController);

    /// @notice The duration of each round, specified in seconds.
    function ROUND_DURATION() external view returns (uint256);

    /// @notice The Revnet loans contract used to borrow against vesting revnet rewards.
    function REV_LOANS() external view returns (IREVLoans);

    /// @notice The REVOwner contract that must own a reward token's project to enable loan-backed collection.
    function REV_OWNER() external view returns (IREVOwner);

    /// @notice The starting timestamp of the distributor.
    function STARTING_TIMESTAMP() external view returns (uint256);

    /// @notice The number of rounds until tokens are fully vested.
    function VESTING_ROUNDS() external view returns (uint256);

    /// @notice The balance of a token held for a specific hook's stakers.
    /// @param hook The hook whose balance to check.
    /// @param token The token to check the balance of.
    function balanceOf(address hook, IERC20 token) external view returns (uint256);

    /// @notice The active Revnet loan using one token ID's vesting rewards as collateral.
    /// @param hook The hook the token ID belongs to.
    /// @param tokenId The token ID whose vesting rewards are collateralized.
    /// @param token The reward token used as loan collateral.
    function activeVestingLoanIdOf(address hook, uint256 tokenId, IERC20 token) external view returns (uint256);

    /// @notice Calculate how much of the token has been claimed for the given tokenId.
    /// @param hook The hook the tokenId belongs to.
    /// @param tokenId The ID of the token to calculate the token amount for.
    /// @param token The address of the token to check.
    function claimedFor(address hook, uint256 tokenId, IERC20 token) external view returns (uint256);

    /// @notice Calculate how much of the token is currently ready to be collected for the given tokenId.
    /// @param hook The hook the tokenId belongs to.
    /// @param tokenId The ID of the token to calculate the token amount for.
    /// @param token The address of the token to check.
    function collectableFor(address hook, uint256 tokenId, IERC20 token) external view returns (uint256);

    /// @notice The number of the current round.
    function currentRound() external view returns (uint256);

    /// @notice The block number recorded as the snapshot point for a round.
    /// @dev Returns 0 if no snapshot block has been recorded yet for this round.
    /// @param round The round to get the snapshot block of.
    function roundSnapshotBlock(uint256 round) external view returns (uint256);

    /// @notice The timestamp at which a round started.
    /// @param round The round to get the start timestamp of.
    function roundStartTimestamp(uint256 round) external view returns (uint256);

    /// @notice The amount of a token that is currently vesting for a hook's stakers.
    /// @param hook The hook whose vesting amount to check.
    /// @param token The address of the token that is vesting.
    function totalVestingAmountOf(address hook, IERC20 token) external view returns (uint256);

    /// @notice The amount of vesting inventory currently collateralized in Revnet loans.
    /// @param hook The hook whose loaned vesting amount to check.
    /// @param token The reward token used as collateral.
    function totalLoanedVestingAmountOf(address hook, IERC20 token) external view returns (uint256);

    /// @notice The vesting position collateralized by a Revnet loan.
    /// @param loanId The Revnet loan NFT ID.
    function vestingLoanOf(uint256 loanId) external view returns (JBVestingLoan memory);

    //*********************************************************************//
    // ---------------------------- transactions ------------------------- //
    //*********************************************************************//

    /// @notice Claims tokens and begins vesting.
    /// @param hook The hook whose stakers are vesting.
    /// @param tokenIds The IDs to claim rewards for.
    /// @param tokens The tokens to claim.
    function beginVesting(address hook, uint256[] calldata tokenIds, IERC20[] calldata tokens) external;

    /// @notice Borrow from a revnet using one token ID's uncollected vesting rewards as collateral.
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
        external
        returns (uint256 loanId, uint256 collateralCount);

    /// @notice Collect vested tokens.
    /// @param hook The hook whose stakers are collecting.
    /// @param tokenIds The IDs of the tokens to collect for.
    /// @param tokens The addresses of the tokens to collect.
    /// @param beneficiary The recipient of the collected tokens.
    function collectVestedRewards(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external;

    /// @notice Fund the distributor for a specific hook.
    /// @dev For native ETH, send `msg.value` and pass `IERC20(NATIVE_TOKEN)` as the token.
    /// @param hook The hook to fund.
    /// @param token The token to fund with.
    /// @param amount The amount to fund.
    function fund(address hook, IERC20 token, uint256 amount) external payable;

    /// @notice Recycle unclaimed rewards from expired reward rounds into the current reward round.
    /// @param hook The hook whose expired reward rounds should be recycled.
    /// @param token The reward token to recycle.
    /// @param rounds The reward rounds to recycle.
    /// @return amount The total amount recycled.
    function burnExpiredRewards(address hook, IERC20 token, uint256[] calldata rounds) external returns (uint256 amount);

    /// @notice Record the snapshot block for the current round. Callable by anyone (keepers, frontends).
    function poke() external;

    /// @notice Repay a distributor-held Revnet loan and restore its collateral to the original vesting schedule.
    /// @param loanId The Revnet loan NFT ID to repay.
    /// @param maxRepayBorrowAmount The maximum amount of source token the caller is willing to repay.
    /// @return paidOffLoanId The paid-off loan ID returned by Revnet loans.
    function repayVestingLoan(
        uint256 loanId,
        uint256 maxRepayBorrowAmount
    )
        external
        payable
        returns (uint256 paidOffLoanId);

    /// @notice Recycle unlocked rewards from burned tokens into the current reward round.
    /// @param hook The hook whose tokens were burned.
    /// @param tokenIds The IDs of the burned tokens.
    /// @param tokens The reward tokens to recycle.
    /// @param beneficiary Unused for forfeiture.
    function releaseForfeitedRewards(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external;

    /// @notice Write off a distributor-held Revnet loan after Revnet liquidation permanently destroys its collateral.
    /// @param loanId The liquidated Revnet loan NFT ID.
    /// @return collateralCount The amount of vesting rewards forfeited by liquidation.
    function writeOffLiquidatedVestingLoan(uint256 loanId) external returns (uint256 collateralCount);
}
