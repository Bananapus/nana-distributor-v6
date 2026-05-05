// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {JBTokenSnapshotData} from "../structs/JBTokenSnapshotData.sol";

/// @notice Interface for round-based reward distributors with linear vesting. Stakers claim their share of a
/// distributable balance each round, and claimed amounts vest linearly over a configurable number of rounds.
/// Two implementations exist: `JBTokenDistributor` (IVotes token stakers) and `JB721Distributor` (NFT holders).
interface IJBDistributor {
    //*********************************************************************//
    // -------------------------------- events --------------------------- //
    //*********************************************************************//

    /// @notice Emitted when a staker begins vesting tokens.
    /// @param hook The hook whose stakers are vesting.
    /// @param tokenId The ID of the staked token that is claiming.
    /// @param token The address of the token to vest.
    /// @param amount The amount of tokens to vest.
    /// @param vestingReleaseRound The round at which the tokens will be fully released.
    event Claimed(
        address indexed hook, uint256 indexed tokenId, IERC20 token, uint256 amount, uint256 vestingReleaseRound
    );

    /// @notice Emitted when vested tokens are collected.
    /// @param hook The hook whose stakers are collecting.
    /// @param tokenId The ID of the staked token collecting.
    /// @param token The address of the token collected.
    /// @param amount The amount of tokens collected.
    /// @param vestingReleaseRound The round at which the tokens will be fully released.
    event Collected(
        address indexed hook, uint256 indexed tokenId, IERC20 token, uint256 amount, uint256 vestingReleaseRound
    );

    /// @notice Emitted when a snapshot block is first recorded for a round.
    /// @param round The round the snapshot block was recorded for.
    /// @param snapshotBlock The block number recorded as the snapshot point.
    event RoundSnapshotRecorded(uint256 indexed round, uint256 snapshotBlock);

    /// @notice Emitted when a snapshot is created for a round.
    /// @param hook The hook the snapshot is for.
    /// @param round The round the snapshot was created for.
    /// @param token The token the snapshot is of.
    /// @param balance The token balance at the time of the snapshot.
    /// @param vestingAmount The amount of tokens vesting at the time of the snapshot.
    event SnapshotCreated(
        address indexed hook, uint256 indexed round, IERC20 indexed token, uint256 balance, uint256 vestingAmount
    );

    //*********************************************************************//
    // ----------------------------- views ------------------------------- //
    //*********************************************************************//

    /// @notice The balance of a token held for a specific hook's stakers.
    /// @param hook The hook whose balance to check.
    /// @param token The token to check the balance of.
    function balanceOf(address hook, IERC20 token) external view returns (uint256);

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

    /// @notice The duration of each round, specified in seconds.
    function roundDuration() external view returns (uint256);

    /// @notice The block number recorded as the snapshot point for a round.
    /// @dev Returns 0 if no snapshot block has been recorded yet for this round.
    /// @param round The round to get the snapshot block of.
    function roundSnapshotBlock(uint256 round) external view returns (uint256);

    /// @notice The timestamp at which a round started.
    /// @param round The round to get the start timestamp of.
    function roundStartTimestamp(uint256 round) external view returns (uint256);

    /// @notice The snapshot data of the token information for each round.
    /// @param hook The hook the snapshot is for.
    /// @param token The address of the token to check.
    /// @param round The round to which the data applies.
    function snapshotAtRoundOf(
        address hook,
        IERC20 token,
        uint256 round
    )
        external
        view
        returns (JBTokenSnapshotData memory);

    /// @notice The amount of a token that is currently vesting for a hook's stakers.
    /// @param hook The hook whose vesting amount to check.
    /// @param token The address of the token that is vesting.
    function totalVestingAmountOf(address hook, IERC20 token) external view returns (uint256);

    /// @notice The number of rounds until tokens are fully vested.
    function vestingRounds() external view returns (uint256);

    //*********************************************************************//
    // ---------------------------- transactions ------------------------- //
    //*********************************************************************//

    /// @notice Claims tokens and begins vesting.
    /// @param hook The hook whose stakers are vesting.
    /// @param tokenIds The IDs to claim rewards for.
    /// @param tokens The tokens to claim.
    function beginVesting(address hook, uint256[] calldata tokenIds, IERC20[] calldata tokens) external;

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

    /// @notice Record the snapshot block for the current round. Callable by anyone (keepers, frontends).
    function poke() external;

    /// @notice Release vested rewards for burned tokens.
    /// @param hook The hook whose tokens were burned.
    /// @param tokenIds The IDs of the burned tokens.
    /// @param tokens The addresses of the tokens to release.
    /// @param beneficiary The recipient of the released tokens.
    function releaseForfeitedRewards(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external;
}
