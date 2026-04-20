// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @custom:member balance The token balance at the time of the snapshot.
/// @custom:member vestingAmount The amount of tokens vesting at the time of the snapshot.
struct JBTokenSnapshotData {
    uint256 balance;
    uint256 vestingAmount;
}
