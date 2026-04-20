// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IJBTokenDistributor} from "./interfaces/IJBTokenDistributor.sol";
import {JBDistributor} from "./JBDistributor.sol";

/// @notice A singleton distributor that distributes ERC-20 rewards to IVotes-compatible token stakers with linear
/// vesting.
/// @dev Any project can use this distributor by configuring a payout split with
/// `hook = this contract` and `beneficiary = address(their IVotes token)`.
/// @dev The stake weight of each staker is their delegated voting power at round start (via `getPastVotes`).
/// Holders must delegate (even to themselves) to participate. Non-delegated supply stays in pool for future rounds.
/// @dev Implements `IJBSplitHook` so it can receive tokens directly from Juicebox project payout splits.
contract JBTokenDistributor is JBDistributor, IJBTokenDistributor {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the caller is not a terminal or controller for the project.
    error JBTokenDistributor_Unauthorized();

    /// @notice Thrown when a tokenId has non-zero upper bits (above 160), which would alias to the same staker address.
    error JBTokenDistributor_InvalidTokenId();

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The JB directory used to verify terminal/controller callers.
    IJBDirectory public immutable DIRECTORY;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The JB directory used to verify terminal/controller callers.
    /// @param roundDuration_ The minimum amount of time stakers have to claim rewards, specified in blocks.
    /// @param vestingRounds_ The number of rounds until tokens are fully vested.
    constructor(
        IJBDirectory directory,
        uint256 roundDuration_,
        uint256 vestingRounds_
    )
        JBDistributor(roundDuration_, vestingRounds_)
    {
        DIRECTORY = directory;
    }

    //*********************************************************************//
    // ---------------------- receive ----------------------------------- //
    //*********************************************************************//

    /// @notice Allows the contract to receive native ETH (e.g. from payout splits).
    receive() external payable {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Receives tokens from a Juicebox payout split.
    /// @dev Only callable by a terminal or controller for the project in the context.
    /// @dev The hook address (IVotes token) is read from `context.split.beneficiary`.
    /// @param context The split hook context from the terminal or controller.
    function processSplitWith(JBSplitHookContext calldata context) external payable override {
        // Only terminals and controllers for the project can call this.
        if (
            !DIRECTORY.isTerminalOf(context.projectId, IJBTerminal(msg.sender))
                && DIRECTORY.controllerOf(context.projectId) != IERC165(msg.sender)
        ) revert JBTokenDistributor_Unauthorized();

        // The target hook is the split's beneficiary (the IVotes token address).
        address hook = address(context.split.beneficiary);

        // If it's not a native-token transfer, check if the caller approved tokens (terminal pattern).
        if (msg.value == 0 && context.amount != 0) {
            uint256 balanceBefore = IERC20(context.token).balanceOf(address(this));
            uint256 allowance = IERC20(context.token).allowance(msg.sender, address(this));
            if (allowance >= context.amount) {
                // Terminal pattern: pull tokens via transferFrom.
                IERC20(context.token).safeTransferFrom(msg.sender, address(this), context.amount);
            }
            // For both terminal and controller paths, credit actual received amount (handles fee-on-transfer).
            _balanceOf[hook][IERC20(context.token)] += IERC20(context.token).balanceOf(address(this)) - balanceBefore;
        } else if (msg.value != 0) {
            // Native ETH: credit actual value received.
            _balanceOf[hook][IERC20(context.token)] += msg.value;
        }
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates whether this contract supports the given interface.
    /// @param interfaceId The interface ID to check.
    /// @return A flag indicating support.
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IJBTokenDistributor).interfaceId || interfaceId == type(IJBSplitHook).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Check if the account matches the staker address encoded in the tokenId.
    /// @dev tokenId encodes the staker address as `uint256(uint160(stakerAddress))`.
    /// @param hook Unused — access is determined by the tokenId encoding.
    /// @param tokenId The encoded staker address.
    /// @param account The account to check.
    /// @return canClaim True if the account matches the encoded address.
    function _canClaim(address hook, uint256 tokenId, address account) internal pure override returns (bool canClaim) {
        hook; // Silence unused variable warning.
        if (tokenId >> 160 != 0) revert JBTokenDistributor_InvalidTokenId();
        canClaim = address(uint160(tokenId)) == account;
    }

    /// @notice The delegated voting power of a staker at the current round's start block.
    /// @dev Uses `IVotes.getPastVotes` for checkpointed lookups. The block number is derived from
    /// `roundStartBlock(currentRound())`, which is deterministic within a single transaction and
    /// consistent with the block used for `_totalStake` in `beginVesting`.
    /// @param hook The IVotes-compatible token contract.
    /// @param tokenId The encoded staker address (`uint256(uint160(stakerAddress))`).
    /// @return tokenStakeAmount The delegated voting power at the round start block.
    function _tokenStake(address hook, uint256 tokenId) internal view override returns (uint256 tokenStakeAmount) {
        if (tokenId >> 160 != 0) revert JBTokenDistributor_InvalidTokenId();
        tokenStakeAmount = IVotes(hook).getPastVotes(address(uint160(tokenId)), roundStartBlock(currentRound()));
    }

    /// @notice The total supply of votes at a specific block.
    /// @dev Uses `IVotes.getPastTotalSupply` for checkpointed lookups.
    /// @param hook The IVotes-compatible token contract.
    /// @param blockNumber The block number to get the total supply at.
    /// @return totalStakedAmount The total supply of votes at the given block.
    function _totalStake(address hook, uint256 blockNumber) internal view override returns (uint256 totalStakedAmount) {
        totalStakedAmount = IVotes(hook).getPastTotalSupply(blockNumber);
    }

    /// @notice IVotes tokens cannot be "burned" in the NFT sense — always returns false.
    /// @dev `releaseForfeitedRewards` will always revert for this distributor.
    /// @param hook Unused.
    /// @param tokenId Unused.
    /// @return tokenWasBurned Always false.
    function _tokenBurned(address hook, uint256 tokenId) internal pure override returns (bool tokenWasBurned) {
        hook;
        tokenId;
        tokenWasBurned = false;
    }
}
