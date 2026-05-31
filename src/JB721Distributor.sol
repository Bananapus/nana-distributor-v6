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

    /// @notice Thrown when a tier-scoped call's tier IDs are not strictly increasing (so a canonical group ID
    /// cannot be derived).
    error JB721Distributor_TierIdsNotIncreasing(uint256 previousTierId, uint256 tierId);

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
    /// @custom:param groupId The reward group (0 = all tiers).
    /// @custom:param tokenId The NFT token ID.
    /// @custom:param token The reward token being claimed.
    mapping(
        address hook => mapping(uint256 groupId => mapping(uint256 tokenId => mapping(IERC20 token => uint256)))
    ) public nextClaimRoundOf;

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

    /// @notice The tier set that defines a reward group, recorded the first time the group is funded.
    /// @dev Empty for the default group (0 = all tiers). Read by the stake math to scope the tier-set denominator.
    /// @custom:param hook The hook the group belongs to.
    /// @custom:param groupId The reward group.
    mapping(address hook => mapping(uint256 groupId => uint256[])) internal _tierIdsOfGroup;

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
                // Split-funded pots go to the all-tiers group (0); a split cannot carry a tier set.
                _recordRewardFunding({hook: hook, groupId: 0, token: IERC20(context.token), amount: msg.value});
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

            // Assign only the amount actually received to this round's reward pot (all-tiers group, 0).
            _recordRewardFunding({hook: hook, groupId: 0, token: IERC20(context.token), amount: delta});
        }
    }

    // The group-0 (all-tiers) `beginVesting` and `collectVestedRewards` are provided by `JBDistributor`. Both
    // distributors share the exact same flow (authorize -> materialize past rounds via `_claimPastRewards` ->
    // optionally release unlocked), so the round-claim logic lives once in the base and dispatches to this contract's
    // `_claimPastRewards` / `_requireCanClaimTokenIds` overrides below. The tier-scoped overloads below derive a
    // canonical group ID from the tier set and call the same base helpers.

    /// @notice Begin vesting all unclaimed past reward rounds for the specified NFT token IDs in a tier-scoped group.
    /// @param hook The 721 hook whose NFT owners are vesting.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenIds The NFT token IDs to claim rewards for.
    /// @param tokens The reward tokens to begin vesting.
    function beginVesting(
        address hook,
        uint256[] calldata tierIds,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens
    )
        external
        override
    {
        _beginVesting({hook: hook, groupId: _groupIdFor(tierIds), tokenIds: tokenIds, tokens: tokens});
    }

    /// @notice Fund a tier-scoped reward group: only holders of the given tiers can claim this pot.
    /// @dev For native ETH, send `msg.value` and pass `IERC20(JBConstants.NATIVE_TOKEN)` as the token. Uses balance
    /// delta to handle fee-on-transfer tokens correctly. The tier set is recorded on the group's first funding.
    /// @param hook The 721 hook to fund (determines which staker pool receives the tokens).
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param token The token to fund with.
    /// @param amount The amount to fund (ignored for native ETH — `msg.value` is used instead).
    function fund(address hook, uint256[] calldata tierIds, IERC20 token, uint256 amount) external payable override {
        // Derive the canonical group ID for the tier set.
        uint256 groupId = _groupIdFor(tierIds);

        // Record the tier set the first time a tier-scoped group is funded, so the stake math can scope it later.
        if (groupId != 0 && _tierIdsOfGroup[hook][groupId].length == 0) {
            _tierIdsOfGroup[hook][groupId] = tierIds;
        }

        _fund({hook: hook, groupId: groupId, token: token, amount: amount});
    }

    /// @notice Recycle unclaimed rewards from expired tier-scoped reward rounds into the current reward round.
    /// @param hook The 721 hook whose expired rewards should be recycled.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param token The reward token to recycle.
    /// @param rounds The reward rounds to recycle.
    /// @return amount The total amount recycled.
    function burnExpiredRewards(
        address hook,
        uint256[] calldata tierIds,
        IERC20 token,
        uint256[] calldata rounds
    )
        external
        override
        returns (uint256 amount)
    {
        amount = _burnExpiredRewards({hook: hook, groupId: _groupIdFor(tierIds), token: token, rounds: rounds});
    }

    /// @notice Recycle unlocked rewards tied to burned NFTs in a tier-scoped group into the current reward round.
    /// @dev Anyone can call this for burned tokens.
    /// @param hook The 721 hook whose NFTs were burned.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenIds The IDs of the burned NFTs (reverts if any are not actually burned).
    /// @param tokens The reward tokens to recycle.
    /// @param beneficiary Unused for forfeiture. Kept for interface compatibility.
    function releaseForfeitedRewards(
        address hook,
        uint256[] calldata tierIds,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external
        override
    {
        _releaseForfeitedRewards({
            hook: hook, groupId: _groupIdFor(tierIds), tokenIds: tokenIds, tokens: tokens, beneficiary: beneficiary
        });
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice Calculate the total uncollected (vesting + vested-but-uncollected) amount for an NFT token ID in a
    /// tier-scoped group.
    /// @param hook The 721 hook the tokenId belongs to.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenId The ID of the NFT token to calculate for.
    /// @param token The reward token to check.
    /// @return tokenAmount The total uncollected amount (vesting + vested-but-uncollected).
    function claimedFor(
        address hook,
        uint256[] calldata tierIds,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        override
        returns (uint256 tokenAmount)
    {
        tokenAmount =
            _unclaimedVestingAmountOf({hook: hook, groupId: _groupIdFor(tierIds), tokenId: tokenId, token: token});
    }

    /// @notice Calculate how much of a reward token is currently unlocked and ready to be collected for a given NFT
    /// token ID in a tier-scoped group.
    /// @param hook The 721 hook the tokenId belongs to.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenId The ID of the NFT token to calculate for.
    /// @param token The reward token to check.
    /// @return tokenAmount The amount of tokens that can be collected right now via `collectVestedRewards`.
    function collectableFor(
        address hook,
        uint256[] calldata tierIds,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        override
        returns (uint256 tokenAmount)
    {
        tokenAmount = _collectableFor({hook: hook, groupId: _groupIdFor(tierIds), tokenId: tokenId, token: token});
    }

    /// @notice The tier set that defines a reward group, recorded when the group is first funded.
    /// @param hook The 721 hook the group belongs to.
    /// @param groupId The reward group.
    /// @return tierIds The strictly-increasing tier set defining the group (empty for the all-tiers group, 0).
    function tierIdsOf(address hook, uint256 groupId) external view override returns (uint256[] memory tierIds) {
        tierIds = _tierIdsOfGroup[hook][groupId];
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Begin vesting then collect everything unlocked for a tier-scoped reward group.
    /// @param hook The 721 hook whose NFT owners are collecting.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenIds The IDs of the NFTs to collect for (caller must be authorized for all of them).
    /// @param tokens The reward tokens to collect vested amounts of.
    /// @param beneficiary The recipient of the collected tokens.
    function collectVestedRewards(
        address hook,
        uint256[] calldata tierIds,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external
        override
    {
        _collectVestedRewards({
            hook: hook, groupId: _groupIdFor(tierIds), tokenIds: tokenIds, tokens: tokens, beneficiary: beneficiary
        });
    }

    /// @notice Borrow against one NFT token ID's uncollected vesting rewards in a tier-scoped group.
    /// @param hook The 721 hook whose NFT owner is borrowing against vesting rewards.
    /// @param tierIds The strictly-increasing tier set defining the group.
    /// @param tokenIds The single NFT token ID to borrow against.
    /// @param tokens The single revnet reward token to collateralize.
    /// @param sourceToken The token to borrow from the revnet.
    /// @param minBorrowAmount The minimum amount to borrow, denominated in `sourceToken`.
    /// @param prepaidFeePercent The fee percent to charge upfront.
    /// @param beneficiary The recipient of the borrowed funds.
    /// @return loanId The Revnet loan NFT ID held by this distributor.
    /// @return collateralCount The amount of vesting rewards used as collateral.
    function borrowAgainstVesting(
        address hook,
        uint256[] calldata tierIds,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address sourceToken,
        uint256 minBorrowAmount,
        uint256 prepaidFeePercent,
        address payable beneficiary
    )
        external
        override
        returns (uint256 loanId, uint256 collateralCount)
    {
        (loanId, collateralCount) = _borrowAgainstVestingFor({
            hook: hook,
            groupId: _groupIdFor(tierIds),
            tokenIds: tokenIds,
            tokens: tokens,
            sourceToken: sourceToken,
            minBorrowAmount: minBorrowAmount,
            prepaidFeePercent: prepaidFeePercent,
            beneficiary: beneficiary
        });
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
    /// @param groupId The reward group being claimed (0 = all tiers).
    /// @param tokenIds The NFT token IDs to claim for.
    /// @param tokens The reward tokens to claim.
    function _claimPastRewards(
        address hook,
        uint256 groupId,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens
    )
        internal
        override
    {
        // Round 0 has no completed reward rounds behind it, so nothing can be claimed yet.
        uint256 round = currentRound();
        if (round == 0) return;

        // Current-round funding is excluded. It becomes claimable only after a later round starts. For a tier-scoped
        // group, load the tier set once so per-token eligibility can be checked without repeated storage reads.
        JBClaimContext memory ctx = JBClaimContext({
            hook: hook,
            groupId: groupId,
            tierIds: groupId == 0 ? new uint256[](0) : _tierIdsOfGroup[hook][groupId],
            lastClaimableRound: round - 1,
            vestingReleaseRound: round + VESTING_ROUNDS
        });

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
            uint256 nextClaimRound = nextClaimRoundOf[ctx.hook][ctx.groupId][tokenIds[i]][token];
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
            JBRewardRoundData storage rewardRound = rewardRoundOf[ctx.hook][ctx.groupId][token][rewardRoundNumber];

            // Skip rounds that never received funding.
            if (rewardRound.amount != 0) {
                // Expired rounds can no longer be claimed as-is; recycle their unclaimed remainder instead.
                if (_rewardRoundExpired(rewardRound)) {
                    _recycleExpiredRewardRound({
                        hook: ctx.hook, groupId: ctx.groupId, token: token, round: rewardRoundNumber
                    });
                } else if (rewardRound.totalStake != 0) {
                    // Bundle the fixed round data used by every NFT in the batch.
                    JBVestContext memory vestCtx = JBVestContext({
                        hook: ctx.hook,
                        groupId: ctx.groupId,
                        tierIds: ctx.tierIds,
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
            nextClaimRoundOf[ctx.hook][ctx.groupId][tokenId][token] = ctx.lastClaimableRound + 1;

            // All accumulated past rewards for this NFT start a single fresh vesting schedule at the claim round.
            if (tokenAmounts[i] != 0) {
                vestingDataOf[ctx.hook][ctx.groupId][tokenId][token].push(
                    JBVestingData({releaseRound: ctx.vestingReleaseRound, amount: tokenAmounts[i], shareClaimed: 0})
                );

                emit Claimed({
                    hook: ctx.hook,
                    tokenId: tokenId,
                    groupId: ctx.groupId,
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
        // Tier-scoped groups distribute a tier's pot among that tier's eligible NFTs. Each NFT contributes its tier's
        // voting units, with no per-owner cap: the denominator (summed `getPastTierVotingUnits`) counts exactly those
        // eligible NFTs, so the shares reconcile without the all-tiers delegation-cap machinery.
        if (ctx.groupId != 0) {
            for (uint256 j; j < tokenIds.length;) {
                if (nextClaimRoundOf[ctx.hook][ctx.groupId][tokenIds[j]][ctx.token] <= ctx.rewardRound) {
                    uint256 stake = _tierScopedStake({ctx: ctx, tokenId: tokenIds[j]});
                    if (stake != 0) {
                        uint256 tokenAmount =
                            mulDiv({x: ctx.distributable, y: stake, denominator: ctx.totalStakeAmount});
                        tokenAmounts[j] += tokenAmount;
                        totalVestingAmount += tokenAmount;
                    }
                }

                unchecked {
                    ++j;
                }
            }

            return totalVestingAmount;
        }

        // All-tiers group (0): split the pot pro-rata across delegated voting power, capping each owner so multiple
        // NFTs cannot over-claim beyond the owner's checkpointed votes.
        // Allocate scratch arrays sized to the maximum possible number of distinct snapshot owners.
        address[] memory owners = new address[](tokenIds.length);
        uint256[] memory consumed = new uint256[](tokenIds.length);
        uint256 uniqueCount;

        // Claim each token ID that has not yet advanced past this reward round.
        for (uint256 j; j < tokenIds.length;) {
            if (nextClaimRoundOf[ctx.hook][0][tokenIds[j]][ctx.token] <= ctx.rewardRound) {
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

    /// @notice Derive the canonical group ID for a tier set. The empty set is the all-tiers group (0).
    /// @param tierIds Strictly-increasing tier IDs; empty for the all-tiers group.
    /// @return groupId 0 for the all-tiers group, else `keccak256(abi.encode(tierIds))`.
    function _groupIdFor(uint256[] calldata tierIds) internal pure returns (uint256 groupId) {
        if (tierIds.length == 0) return 0;
        for (uint256 i = 1; i < tierIds.length;) {
            if (tierIds[i] <= tierIds[i - 1]) {
                revert JB721Distributor_TierIdsNotIncreasing({previousTierId: tierIds[i - 1], tierId: tierIds[i]});
            }
            unchecked {
                ++i;
            }
        }
        groupId = uint256(keccak256(abi.encode(tierIds)));
    }

    /// @notice Whether a tier ID is present in a strictly-increasing tier set.
    /// @param tierId The tier ID to look for.
    /// @param tierIds The strictly-increasing tier set to search.
    /// @return found True if `tierId` is in `tierIds`.
    function _isTierInSet(uint256 tierId, uint256[] memory tierIds) internal pure returns (bool found) {
        for (uint256 i; i < tierIds.length;) {
            if (tierIds[i] == tierId) return true;
            // The set is strictly increasing, so once an entry exceeds the target it cannot appear later.
            if (tierIds[i] > tierId) return false;
            unchecked {
                ++i;
            }
        }
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

    /// @notice The tier-scoped stake of a single NFT in a reward round: its tier's voting units if the NFT's tier is
    /// in the group's set and the NFT existed at the round snapshot, else zero.
    /// @dev No per-owner cap is applied. Eligibility (`ownerOfAt != 0`) plus tier membership matches exactly the set
    /// counted by the `getPastTierVotingUnits` denominator, so per-NFT shares reconcile against the pot.
    /// @param ctx The reward-round context (carries the group's tier set and snapshot block).
    /// @param tokenId The NFT token ID to weigh.
    /// @return stake The NFT's tier voting units, or 0 if ineligible.
    function _tierScopedStake(JBVestContext memory ctx, uint256 tokenId) internal view returns (uint256 stake) {
        // The NFT's tier must be one of the funded tiers.
        uint256 tierId = IJB721TiersHook(ctx.hook).STORE().tierIdOfToken(tokenId);
        if (!_isTierInSet({tierId: tierId, tierIds: ctx.tierIds})) return 0;

        // The NFT must have existed at the round snapshot block (proven via the checkpoint owner history).
        if (_snapshotOwnerOf({hook: ctx.hook, tokenId: tokenId, snapshotBlock: ctx.snapshotBlock}) == address(0)) {
            return 0;
        }

        // Eligible: weigh the NFT by its tier's voting units.
        stake =
        IJB721TiersHook(ctx.hook)
        .STORE()
        .tierOfTokenId({hook: ctx.hook, tokenId: tokenId, includeResolvedUri: false}).votingUnits;
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

    /// @notice The total stake sharing a group's round rewards at a specific block.
    /// @dev For the all-tiers group (0) this is `getPastTotalSupply` from the hook's checkpoints module (all NFTs that
    /// existed and were delegated at `blockNumber`). For a tier-scoped group it is the summed
    /// `getPastTierVotingUnits` over the group's tier set — the eligible voting units of those tiers at the snapshot.
    /// @param hook The hook to get the total stake for.
    /// @param groupId The reward group (0 = all tiers).
    /// @param blockNumber The block number to get the total staked amount at.
    /// @return total The total stake at the given block.
    function _totalStake(
        address hook,
        uint256 groupId,
        uint256 blockNumber
    )
        internal
        view
        override
        returns (uint256 total)
    {
        IJB721Checkpoints checkpoints = IJB721TiersHook(hook).checkpoints();

        // All-tiers group (0): the global checkpointed voting supply.
        if (groupId == 0) {
            return IVotes(address(checkpoints)).getPastTotalSupply(blockNumber);
        }

        // Tier-scoped group: sum the eligible voting units of each tier in the set at the snapshot block.
        uint256[] memory tierIds = _tierIdsOfGroup[hook][groupId];
        for (uint256 i; i < tierIds.length;) {
            total += checkpoints.getPastTierVotingUnits({tierId: tierIds[i], blockNumber: blockNumber});
            unchecked {
                ++i;
            }
        }
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
}
