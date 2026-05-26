// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJB721Checkpoints} from "@bananapus/721-hook-v6/src/interfaces/IJB721Checkpoints.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {mulDiv} from "@prb/math/src/Common.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";

import {JBDistributor} from "./JBDistributor.sol";
import {IJB721Distributor} from "./interfaces/IJB721Distributor.sol";
import {IJBDistributor} from "./interfaces/IJBDistributor.sol";
import {JBClaimContext} from "./structs/JBClaimContext.sol";
import {JBRewardRoundData} from "./structs/JBRewardRoundData.sol";
import {JBVestContext} from "./structs/JBVestContext.sol";
import {JBVestingData} from "./structs/JBVestingData.sol";

/// @notice A singleton distributor that distributes ERC-20 rewards to JB 721 NFT stakers with linear vesting.
/// @dev Any project can use this distributor by configuring a payout split with
/// `hook = this contract` and `beneficiary = address(their 721 hook)`.
/// @dev The stake weight of each NFT is its tier's `votingUnits`. Burned NFTs are excluded from the total stake
/// calculation and their unlocked forfeited rewards can be recycled via `releaseForfeitedRewards`.
/// @dev Funded rewards are assigned to the funding round. NFT owners claim historical rounds lazily; all unclaimed
/// past rewards begin vesting when the current NFT owner claims, not when the rewards were funded.
/// @dev Implements `IJBSplitHook` so it can receive tokens directly from Juicebox project payout splits.
contract JB721Distributor is JBDistributor, IJB721Distributor {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when native ETH does not match the split hook context amount.
    error JB721Distributor_NativeAmountMismatch(uint256 msgValue, uint256 contextAmount);

    /// @notice Thrown when claim batch NFT token IDs are not strictly increasing.
    error JB721Distributor_TokenIdsNotIncreasing(uint256 previousTokenId, uint256 tokenId);

    /// @notice Thrown when native ETH is sent but context.token is not NATIVE_TOKEN.
    error JB721Distributor_TokenMismatch(address token, address expectedToken, uint256 msgValue);

    /// @notice Thrown when the caller is not a terminal or controller for the project.
    error JB721Distributor_Unauthorized(uint256 projectId, address caller);

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The JB directory used to verify terminal/controller callers.
    IJBDirectory public immutable DIRECTORY;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The next reward round an NFT token ID has not yet claimed.
    /// @custom:param hook The 721 hook whose NFTs are claiming.
    /// @custom:param tokenId The NFT token ID.
    /// @custom:param token The reward token being claimed.
    mapping(address hook => mapping(uint256 tokenId => mapping(IERC20 token => uint256))) public nextClaimRoundOf;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Tracks voting power consumed per hook/token/reward round/owner to prevent cap resets across calls.
    /// @custom:param hook The hook address.
    /// @custom:param token The reward token.
    /// @custom:param rewardRound The reward round.
    /// @custom:param owner The NFT owner.
    mapping(
        address hook => mapping(IERC20 token => mapping(uint256 rewardRound => mapping(address owner => uint256)))
    ) internal _consumedVotesOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The JB directory used to verify terminal/controller callers.
    /// @param controller The JB controller used for token registry lookups and revnet loan permissions.
    /// @param revLoans The Revnet loans contract used to borrow against vested revnet rewards.
    /// @param revOwner The REVOwner contract that must own revnet reward token projects.
    /// @param initialRoundDuration The duration of each round, specified in seconds.
    /// @param initialVestingRounds The number of rounds until tokens are fully vested.
    /// @param initialClaimDuration The number of seconds claimants have after each reward round becomes claimable.
    constructor(
        IJBDirectory directory,
        IJBController controller,
        IREVLoans revLoans,
        IREVOwner revOwner,
        uint256 initialRoundDuration,
        uint256 initialVestingRounds,
        uint48 initialClaimDuration
    )
        JBDistributor(controller, revLoans, revOwner, initialRoundDuration, initialVestingRounds, initialClaimDuration)
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
    /// @dev Both terminals and controllers grant an ERC-20 allowance before calling — we pull via `transferFrom`.
    /// For native ETH, the terminal sends the amount as `msg.value`.
    /// @param context The split hook context from the terminal or controller.
    function processSplitWith(JBSplitHookContext calldata context) external payable override {
        // Only terminals and controllers for the project can call this.
        if (
            !DIRECTORY.isTerminalOf({projectId: context.projectId, terminal: IJBTerminal(msg.sender)})
                && DIRECTORY.controllerOf(context.projectId) != IERC165(msg.sender)
        ) revert JB721Distributor_Unauthorized({projectId: context.projectId, caller: msg.sender});

        // The target hook is the split's beneficiary.
        address hook = address(context.split.beneficiary);

        // Native splits must conserve the terminal's stated context amount exactly.
        if (context.token == JBConstants.NATIVE_TOKEN) {
            if (msg.value != context.amount) {
                revert JB721Distributor_NativeAmountMismatch({msgValue: msg.value, contextAmount: context.amount});
            }

            if (msg.value != 0) {
                // Assign native split proceeds to the current reward round for this 721 hook.
                _recordRewardFunding({hook: hook, token: IERC20(context.token), amount: msg.value});
            }
        } else {
            // Validate that native ETH is not cross-booked under an ERC-20 token.
            if (msg.value != 0) {
                revert JB721Distributor_TokenMismatch({
                    token: context.token, expectedToken: JBConstants.NATIVE_TOKEN, msgValue: msg.value
                });
            }

            if (context.amount == 0) return;

            // Pull tokens via transferFrom. Both terminals and controllers grant an ERC-20
            // allowance before calling. Balance delta handles fee-on-transfer tokens correctly.
            uint256 delta =
                _acceptErc20FundsFrom({token: IERC20(context.token), from: msg.sender, amount: context.amount});

            // Assign only the amount actually received to this round's reward pot.
            _recordRewardFunding({hook: hook, token: IERC20(context.token), amount: delta});
        }
    }

    /// @notice Snapshot this NFT's past reward rounds and start vesting them now.
    /// @dev Current-round funding is excluded. It becomes claimable once a later round starts.
    /// @param hook The 721 hook whose NFTs are vesting.
    /// @param tokenIds The NFT token IDs to claim for.
    /// @param tokens The reward tokens to begin vesting.
    function beginVesting(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens
    )
        external
        override(JBDistributor, IJBDistributor)
    {
        // Do not let reward-token callbacks mutate claim accounting during an inbound transfer.
        _requireNotAcceptingToken();
        if (tokenIds.length == 0) revert JBDistributor_EmptyTokenIds({tokenIdCount: tokenIds.length});

        // Only the current NFT owner can start vesting for each token ID.
        _requireCanClaimTokenIds({hook: hook, tokenIds: tokenIds});

        // Materialize all unclaimed historical rewards into fresh vesting entries that start now.
        _claimPastRewards({hook: hook, tokenIds: tokenIds, tokens: tokens});
    }

    /// @notice Collect already-vested rewards and first start vesting any unclaimed past reward rounds.
    /// @param hook The 721 hook whose NFTs are collecting.
    /// @param tokenIds The NFT token IDs to collect for.
    /// @param tokens The reward tokens to collect.
    /// @param beneficiary The recipient of collected vested rewards.
    function collectVestedRewards(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        public
        override(JBDistributor, IJBDistributor)
    {
        // Do not let reward-token callbacks mutate claim accounting during an inbound transfer.
        _requireNotAcceptingToken();
        if (tokenIds.length == 0) revert JBDistributor_EmptyTokenIds({tokenIdCount: tokenIds.length});

        // Only the current NFT owner can materialize and collect rewards for each token ID.
        _requireCanClaimTokenIds({hook: hook, tokenIds: tokenIds});

        // Before collecting, bring the token IDs current by starting vesting for any past reward rounds.
        _claimPastRewards({hook: hook, tokenIds: tokenIds, tokens: tokens});

        // Release whatever portion of existing vesting entries has unlocked by this round.
        _unlockRewards({hook: hook, tokenIds: tokenIds, tokens: tokens, beneficiary: beneficiary, ownerClaim: true});
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

    /// @notice Claim all past reward rounds for the given NFT token IDs and reward tokens into fresh vesting entries.
    /// @param hook The 721 hook whose NFT owners are claiming.
    /// @param tokenIds The NFT token IDs to claim for.
    /// @param tokens The reward tokens to claim.
    function _claimPastRewards(address hook, uint256[] calldata tokenIds, IERC20[] calldata tokens) internal override {
        // Round 0 has no completed reward rounds behind it, so nothing can be claimed yet.
        uint256 round = currentRound();
        if (round == 0) return;

        // Current-round funding is excluded. It becomes claimable only after a later round starts.
        JBClaimContext memory ctx =
            JBClaimContext({hook: hook, lastClaimableRound: round - 1, vestingReleaseRound: round + VESTING_ROUNDS});

        // Process each reward token independently because each token has its own round funding and claim cursor.
        for (uint256 i; i < tokens.length;) {
            IERC20 token = tokens[i];
            uint256 totalVestingAmount = _claimPastRewardsForToken({ctx: ctx, tokenIds: tokenIds, token: token});

            // Track the newly claimed amount as vesting, so later collections unlock against it over time.
            if (totalVestingAmount != 0) totalVestingAmountOf[hook][token] += totalVestingAmount;

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Claim one reward token across all completed rounds for a batch of NFT token IDs.
    /// @param ctx The claim-round context.
    /// @param tokenIds The NFT token IDs to claim for.
    /// @param token The reward token to claim.
    /// @return totalVestingAmount The amount added to vesting for this reward token.
    function _claimPastRewardsForToken(
        JBClaimContext memory ctx,
        uint256[] calldata tokenIds,
        IERC20 token
    )
        internal
        returns (uint256 totalVestingAmount)
    {
        uint256[] memory tokenAmounts = new uint256[](tokenIds.length);
        uint256 firstClaimRound = ctx.lastClaimableRound + 1;

        // Find the earliest cursor in the batch, skipping token IDs that are already current.
        for (uint256 i; i < tokenIds.length;) {
            uint256 nextClaimRound = nextClaimRoundOf[ctx.hook][tokenIds[i]][token];
            if (nextClaimRound <= ctx.lastClaimableRound && nextClaimRound < firstClaimRound) {
                firstClaimRound = nextClaimRound;
            }

            unchecked {
                ++i;
            }
        }

        // If every token ID is already current, there is nothing to materialize.
        if (firstClaimRound > ctx.lastClaimableRound) return 0;

        // Walk every unclaimed historical round needed by at least one token ID.
        for (uint256 rewardRoundNumber = firstClaimRound; rewardRoundNumber <= ctx.lastClaimableRound;) {
            // Load this reward round's funding, snapshot, claim counter, and deadline.
            JBRewardRoundData storage rewardRound = rewardRoundOf[ctx.hook][token][rewardRoundNumber];

            // Skip rounds that never received funding.
            if (rewardRound.amount != 0) {
                // Expired rounds can no longer be claimed as-is; recycle their unclaimed remainder instead.
                if (_rewardRoundExpired(rewardRound)) {
                    _recycleExpiredRewardRound({hook: ctx.hook, token: token, round: rewardRoundNumber});
                } else if (rewardRound.totalStake != 0) {
                    // Bundle the fixed round data used by every NFT in the batch.
                    JBVestContext memory vestCtx = JBVestContext({
                        hook: ctx.hook,
                        token: token,
                        distributable: rewardRound.amount,
                        totalStakeAmount: rewardRound.totalStake,
                        vestingReleaseRound: ctx.vestingReleaseRound,
                        rewardRound: rewardRoundNumber,
                        snapshotBlock: rewardRound.snapshotBlock
                    });

                    // Claim this round for every eligible token ID that has not already advanced past it.
                    uint256 roundVestingAmount =
                        _claimRewardRoundForTokenIds({ctx: vestCtx, tokenIds: tokenIds, tokenAmounts: tokenAmounts});

                    // Track only the amount that actually started vesting, leaving zero-vote and dust amounts
                    // recyclable.
                    if (roundVestingAmount != 0) {
                        rewardRound.claimedAmount = _toUint208(uint256(rewardRound.claimedAmount) + roundVestingAmount);

                        // Add this round's vesting amount into the reward token batch total.
                        totalVestingAmount += roundVestingAmount;
                    }
                }
            }

            unchecked {
                ++rewardRoundNumber;
            }
        }

        // Advance cursors even when a token ID earned zero, so empty or zero-stake rounds are not rescanned forever.
        for (uint256 i; i < tokenIds.length;) {
            uint256 tokenId = tokenIds[i];
            nextClaimRoundOf[ctx.hook][tokenId][token] = ctx.lastClaimableRound + 1;

            // All accumulated past rewards for this NFT start a single fresh vesting schedule at the claim round.
            if (tokenAmounts[i] != 0) {
                vestingDataOf[ctx.hook][tokenId][token].push(
                    JBVestingData({releaseRound: ctx.vestingReleaseRound, amount: tokenAmounts[i], shareClaimed: 0})
                );

                emit Claimed({
                    hook: ctx.hook,
                    tokenId: tokenId,
                    token: token,
                    amount: tokenAmounts[i],
                    vestingReleaseRound: ctx.vestingReleaseRound,
                    caller: msg.sender
                });
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Claim one funded historical reward round for a batch of NFT token IDs.
    /// @param ctx The reward-round context.
    /// @param tokenIds The NFT token IDs to claim for.
    /// @param tokenAmounts The cumulative amount to vest for each token ID in `tokenIds`.
    /// @return totalVestingAmount The amount added to vesting from this reward round.
    function _claimRewardRoundForTokenIds(
        JBVestContext memory ctx,
        uint256[] calldata tokenIds,
        uint256[] memory tokenAmounts
    )
        internal
        returns (uint256 totalVestingAmount)
    {
        // Allocate scratch arrays sized to the maximum possible number of distinct snapshot owners.
        address[] memory owners = new address[](tokenIds.length);
        uint256[] memory consumed = new uint256[](tokenIds.length);
        uint256 uniqueCount;

        // Claim each token ID that has not yet advanced past this reward round.
        for (uint256 j; j < tokenIds.length;) {
            if (nextClaimRoundOf[ctx.hook][tokenIds[j]][ctx.token] <= ctx.rewardRound) {
                (uint256 tokenAmount, uint256 newUniqueCount) = _claimRewardRoundForTokenId({
                    ctx: ctx, tokenId: tokenIds[j], owners: owners, consumed: consumed, uniqueCount: uniqueCount
                });

                uniqueCount = newUniqueCount;
                tokenAmounts[j] += tokenAmount;
                totalVestingAmount += tokenAmount;
            }

            unchecked {
                ++j;
            }
        }

        // Persist consumed voting power to storage to prevent cap resets across separate claim calls.
        for (uint256 k; k < uniqueCount;) {
            _consumedVotesOf[ctx.hook][ctx.token][ctx.rewardRound][owners[k]] = consumed[k];
            unchecked {
                ++k;
            }
        }
    }

    /// @notice Claim one NFT token ID for one historical reward round, enforcing the snapshot owner's vote cap.
    /// @param ctx The reward-round context.
    /// @param tokenId The NFT token ID to claim for.
    /// @param owners A scratch array mapping slot indices to snapshot owners for deduplication.
    /// @param consumed A scratch array tracking consumed voting power by owner slot.
    /// @param uniqueCount The number of distinct snapshot owners seen so far in this reward-round batch.
    /// @return tokenAmount The reward amount vested for this token ID.
    /// @return newUniqueCount The updated count of distinct snapshot owners after processing this token ID.
    function _claimRewardRoundForTokenId(
        JBVestContext memory ctx,
        uint256 tokenId,
        address[] memory owners,
        uint256[] memory consumed,
        uint256 uniqueCount
    )
        internal
        view
        returns (uint256 tokenAmount, uint256 newUniqueCount)
    {
        newUniqueCount = uniqueCount;

        uint256 votingUnits =
            IJB721TiersHook(ctx.hook)
        .STORE()
        .tierOfTokenId({hook: ctx.hook, tokenId: tokenId, includeResolvedUri: false}).votingUnits;

        uint256 ownerIndex;
        uint256 pastVotes;
        {
            // Use the funding round's snapshot block, not the block at which the NFT owner finally claims.
            address owner = _snapshotOwnerOf({hook: ctx.hook, tokenId: tokenId, snapshotBlock: ctx.snapshotBlock});
            if (owner == address(0)) return (0, newUniqueCount);

            pastVotes = IVotes(address(IJB721TiersHook(ctx.hook).checkpoints()))
                .getPastVotes({account: owner, timepoint: ctx.snapshotBlock});
            if (pastVotes == 0) return (0, newUniqueCount);

            bool found;
            for (uint256 k; k < newUniqueCount;) {
                if (owners[k] == owner) {
                    ownerIndex = k;
                    found = true;
                    break;
                }
                unchecked {
                    ++k;
                }
            }

            if (!found) {
                ownerIndex = newUniqueCount;
                owners[newUniqueCount] = owner;
                // Initialize from persistent storage to prevent cap resets across separate claim calls.
                consumed[newUniqueCount] = _consumedVotesOf[ctx.hook][ctx.token][ctx.rewardRound][owner];
                unchecked {
                    ++newUniqueCount;
                }
            }
        }

        uint256 remaining = pastVotes > consumed[ownerIndex] ? pastVotes - consumed[ownerIndex] : 0;
        uint256 stake = votingUnits < remaining ? votingUnits : remaining;
        if (stake == 0) return (0, newUniqueCount);

        // The round's reward pot is split pro-rata across checkpointed voting power.
        tokenAmount = mulDiv({x: ctx.distributable, y: stake, denominator: ctx.totalStakeAmount});
        if (tokenAmount == 0) return (0, newUniqueCount);

        // Only non-zero reward claims consume the snapshot owner's voting budget.
        consumed[ownerIndex] += stake;
    }

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
        JBVestContext memory ctx = JBVestContext({
            hook: hook,
            token: token,
            distributable: distributable,
            totalStakeAmount: totalStakeAmount,
            vestingReleaseRound: vestingReleaseRound,
            rewardRound: currentRound(),
            snapshotBlock: roundSnapshotBlock[currentRound()]
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
            _consumedVotesOf[hook][token][ctx.rewardRound][owners[k]] = consumed[k];
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

    /// @notice Revert unless the caller is authorized to claim each NFT token ID.
    /// @param hook The 721 hook whose NFT owners are claiming.
    /// @param tokenIds The NFT token IDs to check.
    function _requireCanClaimTokenIds(address hook, uint256[] calldata tokenIds) internal view override {
        // Each requested NFT must currently belong to msg.sender and appear in strictly increasing order.
        for (uint256 i; i < tokenIds.length;) {
            uint256 tokenId = tokenIds[i];

            if (i != 0 && tokenId <= tokenIds[i - 1]) {
                revert JB721Distributor_TokenIdsNotIncreasing({previousTokenId: tokenIds[i - 1], tokenId: tokenId});
            }

            if (!_canClaim({hook: hook, tokenId: tokenId, account: msg.sender})) {
                revert JBDistributor_NoAccess({hook: hook, tokenId: tokenId, account: msg.sender});
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
        uint256 pastVotes = IVotes(address(IJB721TiersHook(hook).checkpoints()))
            .getPastVotes({account: owner, timepoint: snapshotBlock});

        // If the owner had no voting power at the snapshot block, the token is ineligible.
        if (pastVotes == 0) return 0;

        // Cap at the token's tier voting units — the owner's past votes may cover multiple tokens,
        // but each individual token's stake is at most its tier's voting units.
        tokenStakeAmount = votingUnits < pastVotes ? votingUnits : pastVotes;
    }

    /// @notice The total stake at a specific block, using the hook's checkpoints module for historical accuracy.
    /// @dev Uses `IVotes.getPastTotalSupply` from the hook's checkpoints module. This ensures that only NFTs
    /// that existed (and were delegated) at `blockNumber` are counted, preventing late mints from diluting or
    /// capturing rewards within the current round.
    /// @param hook The hook to get the total stake for.
    /// @param blockNumber The block number to get the total staked amount at.
    /// @return total The total checkpointed voting units at the given block.
    function _totalStake(address hook, uint256 blockNumber) internal view override returns (uint256 total) {
        IJB721Checkpoints checkpoints = IJB721TiersHook(hook).checkpoints();
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
        IJB721Checkpoints checkpoints = IJB721TiersHook(hook).checkpoints();

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
    function _vestSingleToken(
        JBVestContext memory ctx,
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
            uint256 snapshotBlock = ctx.snapshotBlock;
            address owner = _snapshotOwnerOf({hook: ctx.hook, tokenId: tokenId, snapshotBlock: snapshotBlock});
            if (owner == address(0)) return (0, newUniqueCount);

            // Query the owner's checkpointed voting power at the round's snapshot block.
            pastVotes = IVotes(address(IJB721TiersHook(ctx.hook).checkpoints()))
                .getPastVotes({account: owner, timepoint: snapshotBlock});

            // If the snapshot owner had no voting power at the snapshot block, the token is ineligible for this round.
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
                consumed[newUniqueCount] = _consumedVotesOf[ctx.hook][ctx.token][ctx.rewardRound][owner];
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

        // If the effective stake is zero, the owner's budget is exhausted — skip this token.
        if (stake == 0) return (0, newUniqueCount);

        // Calculate the pro-rata reward amount: (distributable * stake) / totalStakeAmount.
        tokenAmount = mulDiv({x: ctx.distributable, y: stake, denominator: ctx.totalStakeAmount});

        // If the pro-rata amount rounds to zero, do not consume the owner's voting budget.
        if (tokenAmount == 0) return (0, newUniqueCount);

        // Record that this owner has consumed additional voting power from their budget.
        consumed[ownerIndex] += stake;

        // Only create a vesting entry and emit an event if there is a non-zero reward.
        // Push a new vesting data entry for this token ID, starting with zero shareClaimed.
        vestingDataOf[ctx.hook][tokenId][ctx.token].push(
            JBVestingData({releaseRound: ctx.vestingReleaseRound, amount: tokenAmount, shareClaimed: 0})
        );

        // Emit the claim event for off-chain indexers.
        emit Claimed({
            hook: ctx.hook,
            tokenId: tokenId,
            token: ctx.token,
            amount: tokenAmount,
            vestingReleaseRound: ctx.vestingReleaseRound,
            caller: msg.sender
        });
    }
}
