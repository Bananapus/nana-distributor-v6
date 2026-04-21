// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJB721Checkpoints} from "@bananapus/721-hook-v6/src/interfaces/IJB721Checkpoints.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {IJB721Distributor} from "./interfaces/IJB721Distributor.sol";
import {JBDistributor} from "./JBDistributor.sol";

/// @notice A singleton distributor that distributes ERC-20 rewards to JB 721 NFT stakers with linear vesting.
/// @dev Any project can use this distributor by configuring a payout split with
/// `hook = this contract` and `beneficiary = address(their 721 hook)`.
/// @dev The stake weight of each NFT is its tier's `votingUnits`. Burned NFTs are excluded from the total stake
/// calculation and their unvested rewards can be reclaimed via `releaseForfeitedRewards`.
/// @dev Implements `IJBSplitHook` so it can receive tokens directly from Juicebox project payout splits.
contract JB721Distributor is JBDistributor, IJB721Distributor {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when the caller is not a terminal or controller for the project.
    error JB721Distributor_Unauthorized();

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The JB directory used to verify terminal/controller callers.
    IJBDirectory public immutable DIRECTORY;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The JB directory used to verify terminal/controller callers.
    /// @param roundDuration_ The duration of each round, specified in seconds.
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
    /// @dev The hook address is read from `context.split.beneficiary`.
    /// @dev The terminal grants an ERC-20 allowance before calling — we pull via `transferFrom`.
    /// The controller sends tokens directly before calling — nothing to pull.
    /// For native ETH, the terminal sends the amount as `msg.value`.
    /// @param context The split hook context from the terminal or controller.
    function processSplitWith(JBSplitHookContext calldata context) external payable override {
        // Only terminals and controllers for the project can call this.
        if (
            !DIRECTORY.isTerminalOf(context.projectId, IJBTerminal(msg.sender))
                && DIRECTORY.controllerOf(context.projectId) != IERC165(msg.sender)
        ) revert JB721Distributor_Unauthorized();

        // The target hook is the split's beneficiary.
        address hook = address(context.split.beneficiary);

        // If it's not a native-token transfer, check if the caller approved tokens (terminal pattern).
        if (msg.value == 0 && context.amount != 0) {
            uint256 balanceBefore = IERC20(context.token).balanceOf(address(this));
            // Check if the caller has granted an allowance (terminal). If so, pull the tokens.
            // The controller sends tokens before calling, so no pull is needed in that case.
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
        return interfaceId == type(IJB721Distributor).interfaceId || interfaceId == type(IJBSplitHook).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Check if the account owns the given NFT token ID.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The ID of the token to check.
    /// @param account The account to check ownership for.
    /// @return canClaim True if the account owns the token.
    function _canClaim(address hook, uint256 tokenId, address account) internal view override returns (bool canClaim) {
        canClaim = IERC721(hook).ownerOf(tokenId) == account;
    }

    /// @notice Checks if the given token was burned.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The tokenId to check.
    /// @return tokenWasBurned True if the token was burned.
    function _tokenBurned(address hook, uint256 tokenId) internal view override returns (bool tokenWasBurned) {
        // slither-disable-next-line unused-return
        try IERC721(hook).ownerOf(tokenId) returns (address) {
            tokenWasBurned = false;
        } catch {
            tokenWasBurned = true;
        }
    }

    /// @notice The stake weight of a given NFT token ID based on its tier's voting units, validated against historical
    /// state.
    /// @dev Returns 0 if the token's current owner had no checkpointed voting power at the round's snapshot block,
    /// preventing late mints from capturing pro-rata rewards within the current round.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The ID of the token to get the stake weight of.
    /// @return tokenStakeAmount The voting units of the token's tier (or 0 if ineligible).
    function _tokenStake(address hook, uint256 tokenId) internal view override returns (uint256 tokenStakeAmount) {
        uint256 votingUnits = IJB721TiersHook(hook).STORE().tierOfTokenId(hook, tokenId, false).votingUnits;

        // Use the checkpoints module to verify the token's owner had voting power at the round's snapshot block.
        // If they had no voting power at that time, this token was minted or acquired after the round started
        // and is not eligible for this round's rewards.
        IJB721Checkpoints checkpoints = IJB721TiersHook(hook).CHECKPOINTS();
        address owner = IERC721(hook).ownerOf(tokenId);
        uint256 pastVotes = IVotes(address(checkpoints)).getPastVotes(owner, roundSnapshotBlock[currentRound()]);

        // If the owner had no voting power at round start, the token is ineligible.
        // slither-disable-next-line incorrect-equality
        if (pastVotes == 0) return 0;

        // Cap at the token's tier voting units — the owner's past votes may cover multiple tokens,
        // but each individual token's stake is at most its tier's voting units.
        tokenStakeAmount = votingUnits < pastVotes ? votingUnits : pastVotes;
    }

    /// @notice The total stake at a specific block, using the hook's checkpoints module for historical accuracy.
    /// @dev Uses `IVotes.getPastTotalSupply` from the hook's CHECKPOINTS module. This ensures that only NFTs
    /// that existed (and were delegated) at `blockNumber` are counted, preventing late mints from diluting or
    /// capturing rewards within the current round.
    /// @param hook The hook to get the total stake for.
    /// @param blockNumber The block number to get the total staked amount at.
    /// @return total The total checkpointed voting units at the given block.
    function _totalStake(address hook, uint256 blockNumber) internal view override returns (uint256 total) {
        IJB721Checkpoints checkpoints = IJB721TiersHook(hook).CHECKPOINTS();
        total = IVotes(address(checkpoints)).getPastTotalSupply(blockNumber);
    }
}
