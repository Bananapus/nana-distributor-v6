// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Optional 721 checkpoint interface for proving token ownership at a past block.
interface IJB721HistoricalOwner {
    /// @notice Returns the owner of an NFT at a past block.
    /// @param tokenId The token ID to look up.
    /// @param blockNumber The historical block to query.
    /// @return owner The owner at `blockNumber`, or zero if the token was not owned then.
    function ownerOfAt(uint256 tokenId, uint256 blockNumber) external view returns (address owner);
}
