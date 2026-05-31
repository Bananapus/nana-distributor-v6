// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IJBDistributor} from "./IJBDistributor.sol";

/// @notice A singleton distributor that distributes ERC-20 rewards to JB 721 NFT stakers with linear vesting.
/// @dev Also implements `IJBSplitHook` to receive tokens from payout splits.
/// @dev Projects configure their split with `hook = distributor` and `beneficiary = their721Hook`.
/// @dev Adds tier-scoped reward groups on top of the generic group plumbing: a group is a strictly-increasing tier
/// set, and only NFTs whose tier is in the set can claim that group's pot.
interface IJB721Distributor is IJBDistributor, IJBSplitHook {
    //*********************************************************************//
    // ----------------------------- views ------------------------------- //
    //*********************************************************************//

    /// @notice The JB directory used to verify terminal/controller callers.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice Calculate how much of the token has been claimed for the given tokenId in a tier-scoped group.
    /// @param hook The hook the tokenId belongs to.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenId The ID of the token to calculate the token amount for.
    /// @param token The address of the token to check.
    function claimedFor(
        address hook,
        uint256[] calldata tierIds,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        returns (uint256);

    /// @notice Calculate how much of the token is currently ready to be collected for the given tokenId in a
    /// tier-scoped group.
    /// @param hook The hook the tokenId belongs to.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenId The ID of the token to calculate the token amount for.
    /// @param token The address of the token to check.
    function collectableFor(
        address hook,
        uint256[] calldata tierIds,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        returns (uint256);

    /// @notice The tier set that defines a reward group, recorded when the group is first funded.
    /// @dev Empty for the all-tiers group (0).
    /// @param hook The hook the group belongs to.
    /// @param groupId The reward group.
    /// @return tierIds The strictly-increasing tier set defining the group.
    function tierIdsOf(address hook, uint256 groupId) external view returns (uint256[] memory tierIds);

    //*********************************************************************//
    // ---------------------------- transactions ------------------------- //
    //*********************************************************************//

    /// @notice Claims tokens and begins vesting from a tier-scoped reward group.
    /// @param hook The hook whose stakers are vesting.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenIds The IDs to claim rewards for.
    /// @param tokens The tokens to claim.
    function beginVesting(
        address hook,
        uint256[] calldata tierIds,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens
    )
        external;

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
        external
        returns (uint256 loanId, uint256 collateralCount);

    /// @notice Recycle unclaimed rewards from expired tier-scoped reward rounds into the current reward round.
    /// @param hook The hook whose expired reward rounds should be recycled.
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
        returns (uint256 amount);

    /// @notice Collect vested tokens from a tier-scoped reward group.
    /// @param hook The hook whose stakers are collecting.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenIds The IDs of the tokens to collect for.
    /// @param tokens The addresses of the tokens to collect.
    /// @param beneficiary The recipient of the collected tokens.
    function collectVestedRewards(
        address hook,
        uint256[] calldata tierIds,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external;

    /// @notice Fund a tier-scoped reward group: only holders of the given tiers can claim this pot.
    /// @dev For native ETH, send `msg.value` and pass `IERC20(NATIVE_TOKEN)` as the token.
    /// @param hook The hook to fund.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param token The token to fund with.
    /// @param amount The amount to fund.
    function fund(address hook, uint256[] calldata tierIds, IERC20 token, uint256 amount) external payable;

    /// @notice Recycle unlocked rewards from burned tokens in a tier-scoped group into the current reward round.
    /// @param hook The hook whose tokens were burned.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenIds The IDs of the burned tokens.
    /// @param tokens The reward tokens to recycle.
    /// @param beneficiary Unused for forfeiture.
    function releaseForfeitedRewards(
        address hook,
        uint256[] calldata tierIds,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external;
}
