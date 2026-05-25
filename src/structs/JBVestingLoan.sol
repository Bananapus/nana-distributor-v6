// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Tracks a Revnet loan collateralized by one token ID's vesting rewards.
/// @custom:member hook The hook the token ID belongs to.
/// @custom:member tokenId The token ID whose vesting rewards are collateralized.
/// @custom:member token The revnet reward token used as loan collateral.
/// @custom:member vestingDataCount The vesting-entry boundary collateralized by the loan.
/// @custom:member collateralCount The amount of vesting rewards collateralized.
struct JBVestingLoan {
    address hook;
    uint256 tokenId;
    IERC20 token;
    uint48 vestingDataCount;
    uint256 collateralCount;
}
