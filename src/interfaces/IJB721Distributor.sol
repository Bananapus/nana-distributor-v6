// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";

import {IJBDistributor} from "./IJBDistributor.sol";

/// @notice A singleton distributor that distributes ERC-20 rewards to JB 721 NFT stakers with linear vesting.
/// @dev Also implements `IJBSplitHook` to receive tokens from payout splits.
/// @dev Projects configure their split with `hook = distributor` and `beneficiary = their721Hook`.
interface IJB721Distributor is IJBDistributor, IJBSplitHook {
    /// @notice The JB directory used to verify terminal/controller callers.
    function DIRECTORY() external view returns (IJBDirectory);
}
