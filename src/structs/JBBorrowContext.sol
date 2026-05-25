// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Parameters used while opening a distributor-owned Revnet loan.
/// @custom:member hook The hook whose token ID owns the vesting rewards.
/// @custom:member tokenId The token ID whose vesting rewards are collateralized.
/// @custom:member token The revnet reward token used as loan collateral.
/// @custom:member sourceToken The token borrowed from the revnet.
/// @custom:member minBorrowAmount The minimum amount to borrow.
/// @custom:member prepaidFeePercent The prepaid fee percent used by the loan.
/// @custom:member beneficiary The recipient of the borrowed funds.
/// @custom:member revnetId The revnet whose project token is collateralized.
struct JBBorrowContext {
    address hook;
    uint256 tokenId;
    IERC20 token;
    address sourceToken;
    uint256 minBorrowAmount;
    uint256 prepaidFeePercent;
    address payable beneficiary;
    uint256 revnetId;
}
