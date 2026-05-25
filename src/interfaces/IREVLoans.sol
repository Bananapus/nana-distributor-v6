// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";

import {JBRevnetLoan} from "../structs/JBRevnetLoan.sol";

/// @notice Minimal Revnet loans interface used by distributor loan-backed collection.
interface IREVLoans {
    /// @notice Determines the source fee amount for a loan when paying off a certain amount.
    /// @param loan The loan to determine the source fee for.
    /// @param amount The amount to pay off.
    /// @return sourceFeeAmount The source fee amount for the loan.
    function determineSourceFeeAmount(
        JBRevnetLoan memory loan,
        uint256 amount
    )
        external
        view
        returns (uint256 sourceFeeAmount);

    /// @notice Get a loan's full details.
    /// @param loanId The ID of the loan to look up.
    /// @return loan The loan data.
    function loanOf(uint256 loanId) external view returns (JBRevnetLoan memory loan);

    /// @notice Open a loan by borrowing from a revnet.
    /// @param revnetId The ID of the revnet to borrow from.
    /// @param token The token to borrow from the revnet's canonical terminal.
    /// @param minBorrowAmount The minimum amount to borrow, denominated in `token`.
    /// @param collateralCount The amount of revnet tokens to use as collateral.
    /// @param beneficiary The address that receives the borrowed funds.
    /// @param prepaidFeePercent The fee percent to charge upfront.
    /// @param holder The address whose revnet tokens are used as collateral and receives the loan NFT.
    /// @return loanId The ID of the loan created.
    /// @return loan The loan created.
    function borrowFrom(
        uint256 revnetId,
        address token,
        uint256 minBorrowAmount,
        uint256 collateralCount,
        address payable beneficiary,
        uint256 prepaidFeePercent,
        address holder
    )
        external
        returns (uint256 loanId, JBRevnetLoan memory loan);

    /// @notice Repay a loan or return collateral no longer needed to support the loan.
    /// @param loanId The ID of the loan to repay.
    /// @param maxRepayBorrowAmount The maximum amount to repay.
    /// @param collateralCountToReturn The amount of collateral to return from the loan.
    /// @param beneficiary The address to receive the returned collateral and fee payment tokens.
    /// @param allowance A permit2 allowance to facilitate repayment transfer.
    /// @return paidOffLoanId The ID of the loan after repayment.
    /// @return paidOffLoan The loan after repayment.
    function repayLoan(
        uint256 loanId,
        uint256 maxRepayBorrowAmount,
        uint256 collateralCountToReturn,
        address payable beneficiary,
        JBSingleAllowance calldata allowance
    )
        external
        payable
        returns (uint256 paidOffLoanId, JBRevnetLoan memory paidOffLoan);
}
