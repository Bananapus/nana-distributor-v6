// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A loan against revnet token collateral.
/// @custom:member amount The amount borrowed, including fees taken at creation.
/// @custom:member collateral The number of revnet tokens burned as collateral.
/// @custom:member createdAt The timestamp when the loan was created.
/// @custom:member prepaidFeePercent The percentage of fees prepaid at creation.
/// @custom:member prepaidDuration The duration during which repayment costs no additional fee.
/// @custom:member sourceToken The token borrowed from the revnet's canonical terminal.
struct JBRevnetLoan {
    uint112 amount;
    uint112 collateral;
    uint48 createdAt;
    uint16 prepaidFeePercent;
    uint32 prepaidDuration;
    address sourceToken;
}
