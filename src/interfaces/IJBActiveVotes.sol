// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Provides checkpointed totals for voting units delegated to nonzero delegates.
interface IJBActiveVotes {
    /// @notice The total delegated voting units at a past timepoint.
    /// @param timepoint The past block number to look up.
    /// @return activeVotes The total voting units delegated to nonzero delegates at `timepoint`.
    function getPastTotalActiveVotes(uint256 timepoint) external view returns (uint256 activeVotes);

    /// @notice The current total delegated voting units.
    /// @return activeVotes The current total voting units delegated to nonzero delegates.
    function getTotalActiveVotes() external view returns (uint256 activeVotes);
}
