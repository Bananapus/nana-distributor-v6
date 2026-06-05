// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IJBDistributor} from "./IJBDistributor.sol";

/// @notice A singleton distributor that distributes ERC-20 rewards to IVotes-compatible token stakers with linear
/// vesting.
/// @dev Also implements `IJBSplitHook` to receive tokens from payout splits.
/// @dev Projects configure their split with `hook = distributor` and `beneficiary = their IVotes token`.
interface IJBTokenDistributor is IJBDistributor, IJBSplitHook {
    /// @notice Emitted when a token holder registers snapshot voting power for an active-voter reward round.
    /// @param hook The IVotes token whose stakers are registering.
    /// @param round The reward round being registered for.
    /// @param tokenId The encoded staker address.
    /// @param token The reward token being registered.
    /// @param stake The staker's delegated voting power at the reward round's snapshot block.
    /// @param caller The address that registered.
    event ActiveVoterRegistered(
        address indexed hook,
        uint256 indexed round,
        uint256 indexed tokenId,
        IERC20 token,
        uint256 stake,
        address caller
    );

    /// @notice The JB directory used to verify terminal/controller callers.
    /// @return directory The JB directory.
    function DIRECTORY() external view returns (IJBDirectory);

    /// @notice The snapshot voting power registered by a staker for a token reward round.
    /// @param hook The IVotes token whose stakers are registering.
    /// @param groupId The reward group (0 = the default group).
    /// @param token The reward token.
    /// @param round The reward round.
    /// @param tokenId The encoded staker address.
    /// @return stake The staker's registered snapshot voting power.
    function registeredStakeOf(
        address hook,
        uint256 groupId,
        IERC20 token,
        uint256 round,
        uint256 tokenId
    )
        external
        view
        returns (uint208 stake);
}
