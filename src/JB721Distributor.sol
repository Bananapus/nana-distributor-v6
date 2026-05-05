// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJB721Checkpoints} from "@bananapus/721-hook-v6/src/interfaces/IJB721Checkpoints.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

import {mulDiv} from "@prb/math/src/Common.sol";

import {IJB721Distributor} from "./interfaces/IJB721Distributor.sol";
import {JBDistributor} from "./JBDistributor.sol";
import {JBVestingData} from "./structs/JBVestingData.sol";

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

    /// @notice Thrown when native ETH is sent but context.token is not NATIVE_TOKEN.
    error JB721Distributor_TokenMismatch();

    /// @notice Thrown when the caller is not a terminal or controller for the project.
    error JB721Distributor_Unauthorized();

    //*********************************************************************//
    // ----------------------------- structs ----------------------------- //
    //*********************************************************************//

    /// @dev Bundles per-round vesting parameters to avoid stack-too-deep.
    struct VestContext {
        address hook;
        IERC20 token;
        uint256 distributable;
        uint256 totalStakeAmount;
        uint256 vestingReleaseRound;
    }

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The JB directory used to verify terminal/controller callers.
    IJBDirectory public immutable DIRECTORY;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Tracks voting power consumed per hook/token/round/owner to prevent cap resets across calls.
    /// @custom:param hook The hook address.
    /// @custom:param token The reward token.
    /// @custom:param releaseRound The vesting release round.
    /// @custom:param owner The NFT owner.
    mapping(
        address hook => mapping(IERC20 token => mapping(uint256 releaseRound => mapping(address owner => uint256)))
    ) internal _consumedVotesOf;

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

        // If it's not a native-token transfer, credit the ERC-20 amount.
        if (msg.value == 0 && context.amount != 0) {
            uint256 allowance = IERC20(context.token).allowance(msg.sender, address(this));
            if (allowance >= context.amount) {
                // Terminal path: the caller granted an allowance — pull tokens via transferFrom.
                // Use balance delta to handle fee-on-transfer tokens correctly.
                uint256 balanceBefore = IERC20(context.token).balanceOf(address(this));
                IERC20(context.token).safeTransferFrom(msg.sender, address(this), context.amount);
                uint256 delta = IERC20(context.token).balanceOf(address(this)) - balanceBefore;
                _balanceOf[hook][IERC20(context.token)] += delta;
                _accountedBalanceOf[IERC20(context.token)] += delta;
            } else {
                // Controller-prepaid path: verify actual unaccounted balance covers the declared amount.
                uint256 actual = IERC20(context.token).balanceOf(address(this));
                uint256 unaccounted = actual - _accountedBalanceOf[IERC20(context.token)];
                if (unaccounted < context.amount) revert JBDistributor_UnfundedSplitCredit();
                _accountedBalanceOf[IERC20(context.token)] += context.amount;
                _balanceOf[hook][IERC20(context.token)] += context.amount;
            }
        } else if (msg.value != 0) {
            // Validate that context.token matches NATIVE_TOKEN to prevent cross-booking attacks.
            if (context.token != JBConstants.NATIVE_TOKEN) revert JB721Distributor_TokenMismatch();
            // Native ETH: credit actual value received.
            _balanceOf[hook][IERC20(context.token)] += msg.value;
            _accountedBalanceOf[IERC20(context.token)] += msg.value;
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

    /// @notice Override vesting to cap each owner's consumed voting power across all their NFTs.
    /// @dev Prevents an owner with N NFTs of V voting units each from claiming N*V when their pastVotes < N*V.
    ///      Iterates over all token IDs in the batch, delegating per-token logic to `_vestSingleToken`. A pair of
    ///      scratch arrays (`owners` and `consumed`) tracks how much voting power each distinct owner has used so far,
    ///      ensuring the aggregate claim never exceeds the owner's snapshot voting power.
    ///      Silently skips burned tokens, already-vested tokens, and tokens whose owner had no snapshot voting power.
    /// @param hook The address of the 721 hook whose stakers are vesting.
    /// @param tokenIds The NFT token IDs to vest rewards for.
    /// @param token The ERC-20 reward token to distribute.
    /// @param distributable The total distributable amount of `token` for this round.
    /// @param totalStakeAmount The aggregate voting power at the round's snapshot block.
    /// @param vestingReleaseRound The round number at which the vesting period ends and tokens become fully claimable.
    /// @return totalVestingAmount The sum of reward tokens that began vesting across all processed token IDs.
    function _vestTokenIds(
        address hook,
        uint256[] calldata tokenIds,
        IERC20 token,
        uint256 distributable,
        uint256 totalStakeAmount,
        uint256 vestingReleaseRound
    )
        internal
        override
        returns (uint256 totalVestingAmount)
    {
        // Bundle iteration-constant parameters into a struct to avoid stack-too-deep errors.
        VestContext memory ctx = VestContext({
            hook: hook,
            token: token,
            distributable: distributable,
            totalStakeAmount: totalStakeAmount,
            vestingReleaseRound: vestingReleaseRound
        });

        // Allocate scratch arrays sized to the maximum possible number of distinct owners (one per token ID).
        address[] memory owners = new address[](tokenIds.length);
        uint256[] memory consumed = new uint256[](tokenIds.length);

        // Track how many distinct owners have been recorded in the scratch arrays so far.
        uint256 uniqueCount;

        // Iterate over every token ID in the batch.
        for (uint256 j; j < tokenIds.length;) {
            // Vest the single token, receiving its reward amount and the updated distinct owner count.
            (uint256 tokenAmount, uint256 newUniqueCount) = _vestSingleToken({
                ctx: ctx, tokenId: tokenIds[j], owners: owners, consumed: consumed, uniqueCount: uniqueCount
            });

            // Carry the updated owner count forward so subsequent tokens can reference the same tracking data.
            uniqueCount = newUniqueCount;

            unchecked {
                // Accumulate the individual token's reward into the batch-wide total.
                totalVestingAmount += tokenAmount;
                ++j;
            }
        }

        // Persist consumed voting power to storage to prevent cap resets across calls.
        for (uint256 k; k < uniqueCount;) {
            _consumedVotesOf[hook][token][vestingReleaseRound][owners[k]] = consumed[k];
            unchecked {
                ++k;
            }
        }
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
    /// @dev Returns 0 if the token was not owned at the round's snapshot block or if its snapshot owner had no
    /// checkpointed voting power, preventing late mints from capturing pro-rata rewards within the current round.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The ID of the token to get the stake weight of.
    /// @return tokenStakeAmount The voting units of the token's tier (or 0 if ineligible).
    function _tokenStake(address hook, uint256 tokenId) internal view override returns (uint256 tokenStakeAmount) {
        uint256 votingUnits =
            IJB721TiersHook(hook)
        .STORE()
        .tierOfTokenId({hook: hook, tokenId: tokenId, includeResolvedUri: false}).votingUnits;

        // Stake eligibility is fixed at the round snapshot block, not the caller's current block.
        uint256 snapshotBlock = roundSnapshotBlock[currentRound()];
        address owner = _snapshotOwnerOf({hook: hook, tokenId: tokenId, snapshotBlock: snapshotBlock});
        if (owner == address(0)) return 0;

        // Use the checkpoints module to verify the token's snapshot owner had voting power at the round's snapshot
        // block. If the token did not exist then, ownerOfAt returns zero above and the token is not eligible.
        uint256 pastVotes = IVotes(address(IJB721TiersHook(hook).CHECKPOINTS()))
            .getPastVotes({account: owner, timepoint: snapshotBlock});

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

    //*********************************************************************//
    // ----------------------- private helpers --------------------------- //
    //*********************************************************************//

    /// @notice Returns the token owner at the round snapshot block.
    /// @dev Returns zero if the hook has no checkpoint module, the module does not support historical ownership, the
    /// call fails, or the token was not owned at `snapshotBlock`. Treating all of these as ineligible prevents late
    /// mints and current-owner transfers from claiming rewards for a snapshot they did not participate in.
    /// @param hook The 721 hook whose checkpoint module is queried.
    /// @param tokenId The token ID to query.
    /// @param snapshotBlock The round snapshot block to prove ownership at.
    /// @return owner The historical token owner, or zero if ownership cannot be proven.
    function _snapshotOwnerOf(
        address hook,
        uint256 tokenId,
        uint256 snapshotBlock
    )
        private
        view
        returns (address owner)
    {
        // The 721 hook owns the checkpoint module; the distributor only trusts that module's historical proof.
        IJB721Checkpoints checkpoints = IJB721TiersHook(hook).CHECKPOINTS();

        // Use staticcall so older hooks without `ownerOfAt` fail closed instead of reverting the whole distribution.
        (bool success, bytes memory data) =
            address(checkpoints).staticcall(abi.encodeCall(IJB721Checkpoints.ownerOfAt, (tokenId, snapshotBlock)));
        if (!success || data.length < 32) return address(0);

        // A zero owner means the token was not owned at the snapshot block and is not eligible this round.
        owner = abi.decode(data, (address));
    }

    /// @notice Vest a single NFT token, enforcing a per-owner voting power cap across the batch.
    /// @dev Returns 0 for burned tokens, already-vested tokens, tokens whose owner had no snapshot voting power,
    ///      and tokens whose owner has already exhausted their voting power cap within this batch.
    ///      The `owners` and `consumed` arrays form a compact map that tracks how much voting power each unique
    ///      owner has consumed so far. `uniqueCount` tracks how many slots are used.
    /// @param ctx The vesting context containing hook address, reward token, distributable amount, total stake,
    ///        and release round.
    /// @param tokenId The NFT token ID to process.
    /// @param owners A scratch array mapping slot indices to owner addresses for deduplication within this batch.
    /// @param consumed A scratch array tracking how much voting power each owner (by slot index) has consumed.
    /// @param uniqueCount The number of distinct owners seen so far in the batch.
    /// @return tokenAmount The reward amount vested for this token ID (0 if skipped).
    /// @return newUniqueCount The updated count of distinct owners after processing this token ID.
    // slither-disable-next-line incorrect-equality
    function _vestSingleToken(
        VestContext memory ctx,
        uint256 tokenId,
        address[] memory owners,
        uint256[] memory consumed,
        uint256 uniqueCount
    )
        private
        returns (uint256 tokenAmount, uint256 newUniqueCount)
    {
        // Initialize the return value to the current count of distinct owners.
        newUniqueCount = uniqueCount;

        // Skip burned tokens — they are excluded from _totalStake, so including them would overbook vesting.
        if (_tokenBurned({hook: ctx.hook, tokenId: tokenId})) return (0, newUniqueCount);

        // Skip already-vested tokenIds — check if the last vesting entry targets the same release round.
        {
            // Load the number of existing vesting entries for this token.
            uint256 numVesting = vestingDataOf[ctx.hook][tokenId][ctx.token].length;

            // If at least one entry exists and its release round matches, this token was already vested this round.
            if (
                numVesting != 0
                    && vestingDataOf[ctx.hook][tokenId][ctx.token][numVesting - 1].releaseRound
                        == ctx.vestingReleaseRound
            ) {
                return (0, newUniqueCount);
            }
        }

        // Look up the NFT's voting units from its tier in the hook's store.
        uint256 votingUnits =
            IJB721TiersHook(ctx.hook)
        .STORE()
        .tierOfTokenId({hook: ctx.hook, tokenId: tokenId, includeResolvedUri: false}).votingUnits;

        // Look up the snapshot owner, verify snapshot eligibility, and find or create the owner's tracking slot.
        uint256 ownerIndex;
        uint256 pastVotes;
        {
            // Reuse the same round snapshot block for every token in this vesting batch.
            uint256 snapshotBlock = roundSnapshotBlock[currentRound()];
            address owner = _snapshotOwnerOf({hook: ctx.hook, tokenId: tokenId, snapshotBlock: snapshotBlock});
            if (owner == address(0)) return (0, newUniqueCount);

            // Query the owner's checkpointed voting power at the round's snapshot block.
            pastVotes = IVotes(address(IJB721TiersHook(ctx.hook).CHECKPOINTS()))
                .getPastVotes({account: owner, timepoint: snapshotBlock});

            // If the snapshot owner had no voting power at round start, the token is ineligible for this round.
            // slither-disable-next-line incorrect-equality
            if (pastVotes == 0) return (0, newUniqueCount);

            // Search the owners array for an existing slot belonging to this owner.
            bool found;
            for (uint256 k; k < newUniqueCount;) {
                if (owners[k] == owner) {
                    // Re-use the existing tracking slot for this owner.
                    ownerIndex = k;
                    found = true;
                    break;
                }
                unchecked {
                    ++k;
                }
            }

            // If no existing slot was found, allocate a new one at the end of the arrays.
            if (!found) {
                ownerIndex = newUniqueCount;
                owners[newUniqueCount] = owner;
                // Initialize from persistent storage to prevent cap resets across calls.
                consumed[newUniqueCount] = _consumedVotesOf[ctx.hook][ctx.token][ctx.vestingReleaseRound][owner];
                unchecked {
                    ++newUniqueCount;
                }
            }
        }

        // Cap this NFT's effective stake at the owner's remaining voting power budget for this batch.
        uint256 stake;
        {
            // Calculate how much voting power the owner has left after prior tokens in this batch.
            uint256 remaining = pastVotes > consumed[ownerIndex] ? pastVotes - consumed[ownerIndex] : 0;

            // The effective stake is the lesser of the NFT's voting units and the owner's remaining budget.
            stake = votingUnits < remaining ? votingUnits : remaining;
        }

        // Record that this owner has consumed additional voting power from their budget.
        consumed[ownerIndex] += stake;

        // If the effective stake is zero, the owner's budget is exhausted — skip this token.
        // slither-disable-next-line incorrect-equality
        if (stake == 0) return (0, newUniqueCount);

        // Calculate the pro-rata reward amount: (distributable * stake) / totalStakeAmount.
        tokenAmount = mulDiv({x: ctx.distributable, y: stake, denominator: ctx.totalStakeAmount});

        // Only create a vesting entry and emit an event if there is a non-zero reward.
        if (tokenAmount > 0) {
            // Push a new vesting data entry for this token ID, starting with zero shareClaimed.
            vestingDataOf[ctx.hook][tokenId][ctx.token].push(
                JBVestingData({releaseRound: ctx.vestingReleaseRound, amount: tokenAmount, shareClaimed: 0})
            );

            // Emit the claim event for off-chain indexers.
            emit Claimed(ctx.hook, tokenId, ctx.token, tokenAmount, ctx.vestingReleaseRound);
        }
    }
}
