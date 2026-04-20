// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

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
            // Check if the caller has granted an allowance (terminal). If so, pull the tokens.
            // The controller sends tokens before calling, so no pull is needed in that case.
            uint256 allowance = IERC20(context.token).allowance(msg.sender, address(this));
            if (allowance >= context.amount) {
                // Terminal pattern: pull tokens and credit actual received amount (handles fee-on-transfer).
                uint256 balanceBefore = IERC20(context.token).balanceOf(address(this));
                IERC20(context.token).safeTransferFrom(msg.sender, address(this), context.amount);
                _balanceOf[hook][IERC20(context.token)] += IERC20(context.token).balanceOf(address(this))
                - balanceBefore;
            } else {
                // Controller pattern: tokens already sent before this call, trust context.amount.
                _balanceOf[hook][IERC20(context.token)] += context.amount;
            }
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
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Check if the account owns the given NFT token ID.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The ID of the token to check.
    /// @param account The account to check ownership for.
    /// @return canClaim True if the account owns the token.
    function _canClaim(address hook, uint256 tokenId, address account) internal view override returns (bool canClaim) {
        canClaim = IERC721(hook).ownerOf(tokenId) == account;
    }

    /// @notice The stake weight of a given NFT token ID based on its tier's voting units.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The ID of the token to get the stake weight of.
    /// @return tokenStakeAmount The voting units of the token's tier.
    function _tokenStake(address hook, uint256 tokenId) internal view override returns (uint256 tokenStakeAmount) {
        tokenStakeAmount = IJB721TiersHook(hook).STORE().tierOfTokenId(hook, tokenId, false).votingUnits;
    }

    /// @notice The total stake across all tiers, excluding burned NFTs.
    /// @dev Iterates all tiers and sums `(minted - burned) * votingUnits` per tier.
    /// @param hook The hook to get the total stake for.
    /// @param blockNumber Unused — the 721 hook does not support checkpoints.
    /// @return total The total voting units of all currently held NFTs.
    function _totalStake(address hook, uint256 blockNumber) internal view override returns (uint256 total) {
        // Silence unused variable warning.
        blockNumber;

        IJB721TiersHookStore store = IJB721TiersHook(hook).STORE();
        uint256 maxTierId = store.maxTierIdOf(hook);

        for (uint256 i = 1; i <= maxTierId;) {
            JB721Tier memory tier = store.tierOf(hook, i, false);

            if (tier.initialSupply != 0) {
                // Subtract burned NFTs so they don't dilute active stakers.
                uint256 held = tier.initialSupply - tier.remainingSupply - store.numberOfBurnedFor(hook, i);
                total += held * tier.votingUnits;
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Checks if the given token was burned.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The tokenId to check.
    /// @return tokenWasBurned True if the token was burned.
    function _tokenBurned(address hook, uint256 tokenId) internal view override returns (bool tokenWasBurned) {
        try IERC721(hook).ownerOf(tokenId) returns (address) {
            tokenWasBurned = false;
        } catch {
            tokenWasBurned = true;
        }
    }
}
