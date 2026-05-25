// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBSplitHook} from "@bananapus/core-v6/src/interfaces/IJBSplitHook.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBSplitHookContext} from "@bananapus/core-v6/src/structs/JBSplitHookContext.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {JBDistributor} from "./JBDistributor.sol";
import {IJBDistributor} from "./interfaces/IJBDistributor.sol";
import {IJBTokenDistributor} from "./interfaces/IJBTokenDistributor.sol";
import {JBClaimContext} from "./structs/JBClaimContext.sol";
import {JBRewardRoundData} from "./structs/JBRewardRoundData.sol";
import {JBVestingData} from "./structs/JBVestingData.sol";

/// @notice A singleton distributor that distributes ERC-20 rewards to IVotes-compatible token stakers with linear
/// vesting.
/// @dev Any project can use this distributor by configuring a payout split with
/// `hook = this contract` and `beneficiary = address(their IVotes token)`.
/// @dev The stake weight of each staker is their delegated voting power at the funded round's snapshot block.
/// Holders must delegate (even to themselves) to participate.
/// @dev Funded rewards are assigned to the funding round. Stakers claim historical rounds lazily; all unclaimed past
/// rewards begin vesting when the staker claims, not when the rewards were funded.
/// @dev Implements `IJBSplitHook` so it can receive tokens directly from Juicebox project payout splits.
contract JBTokenDistributor is JBDistributor, IJBTokenDistributor {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when a tokenId has non-zero upper bits (above 160), which would alias to the same staker address.
    error JBTokenDistributor_InvalidTokenId(uint256 tokenId);

    /// @notice Thrown when native ETH does not match the split hook context amount.
    error JBTokenDistributor_NativeAmountMismatch(uint256 msgValue, uint256 contextAmount);

    /// @notice Thrown when native ETH is sent but context.token is not NATIVE_TOKEN.
    error JBTokenDistributor_TokenMismatch(address token, address expectedToken, uint256 msgValue);

    /// @notice Thrown when the caller is not a terminal or controller for the project.
    error JBTokenDistributor_Unauthorized(uint256 projectId, address caller);

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The JB directory used to verify terminal/controller callers.
    IJBDirectory public immutable DIRECTORY;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The next reward round a staker has not yet claimed.
    /// @custom:param hook The IVotes token whose stakers are claiming.
    /// @custom:param tokenId The encoded staker address.
    /// @custom:param token The reward token being claimed.
    mapping(address hook => mapping(uint256 tokenId => mapping(IERC20 token => uint256))) public nextClaimRoundOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The JB directory used to verify terminal/controller callers.
    /// @param controller The JB controller used to burn expired or forfeited project-token rewards.
    /// @param revLoans The Revnet loans contract used to borrow against vested revnet rewards.
    /// @param revOwner The REVOwner contract that must own revnet reward token projects.
    /// @param initialRoundDuration The duration of each round, specified in seconds.
    /// @param initialVestingRounds The number of rounds until tokens are fully vested.
    /// @param initialClaimDuration The number of seconds claimants have after each reward round becomes claimable.
    constructor(
        IJBDirectory directory,
        address controller,
        address revLoans,
        address revOwner,
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
    /// @dev The hook address (IVotes token) is read from `context.split.beneficiary`.
    /// @param context The split hook context from the terminal or controller.
    function processSplitWith(JBSplitHookContext calldata context) external payable override {
        // Only terminals and controllers for the project can call this.
        if (
            !DIRECTORY.isTerminalOf({projectId: context.projectId, terminal: IJBTerminal(msg.sender)})
                && DIRECTORY.controllerOf(context.projectId) != IERC165(msg.sender)
        ) revert JBTokenDistributor_Unauthorized({projectId: context.projectId, caller: msg.sender});

        // The target hook is the split's beneficiary (the IVotes token address).
        address hook = address(context.split.beneficiary);

        // Native splits must conserve the terminal's stated context amount exactly.
        if (context.token == JBConstants.NATIVE_TOKEN) {
            if (msg.value != context.amount) {
                revert JBTokenDistributor_NativeAmountMismatch({msgValue: msg.value, contextAmount: context.amount});
            }

            if (msg.value != 0) {
                // Assign native split proceeds to the current reward round for this IVotes hook.
                _recordRewardFunding({hook: hook, token: IERC20(context.token), amount: msg.value});
            }
        } else {
            // Validate that native ETH is not cross-booked under an ERC-20 token.
            if (msg.value != 0) {
                revert JBTokenDistributor_TokenMismatch({
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

    /// @notice Snapshot this staker's past reward rounds and start vesting them now.
    /// @dev Unlike the shared distributor flow, token claims are owner-initiated. This prevents third parties from
    /// starting a staker's vesting clock before the staker actually claims.
    /// @param hook The IVotes token whose stakers are vesting.
    /// @param tokenIds The encoded staker addresses to claim for.
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

        // Token IDs encode staker addresses, so only the encoded staker can start their own vesting clock.
        _requireCanClaimTokenIds({hook: hook, tokenIds: tokenIds});

        // Materialize all unclaimed historical rewards into fresh vesting entries that start now.
        _claimPastRewards({hook: hook, tokenIds: tokenIds, tokens: tokens});
    }

    /// @notice Collect already-vested rewards and first start vesting any unclaimed past reward rounds.
    /// @param hook The IVotes token whose stakers are collecting.
    /// @param tokenIds The encoded staker addresses to collect for.
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

        // Only the encoded staker can materialize and collect their token rewards.
        _requireCanClaimTokenIds({hook: hook, tokenIds: tokenIds});

        // Before collecting, bring the caller current by starting vesting for any past reward rounds.
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
        return interfaceId == type(IJBTokenDistributor).interfaceId || interfaceId == type(IJBSplitHook).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Claim all past reward rounds for the given token IDs and reward tokens into fresh vesting entries.
    /// @param hook The IVotes token whose stakers are claiming.
    /// @param tokenIds The encoded staker addresses to claim for.
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
            uint256 totalVestingAmount;

            // Materialize this reward token for every staker address encoded in tokenIds.
            for (uint256 j; j < tokenIds.length;) {
                uint256 tokenId = tokenIds[j];
                uint256 tokenAmount = _claimPastRewardsForTokenId({ctx: ctx, tokenId: tokenId, token: token});

                // Accumulate once per reward token so totalVestingAmountOf is updated with one storage write.
                totalVestingAmount += tokenAmount;

                unchecked {
                    ++j;
                }
            }

            // Track the newly claimed amount as vesting, so later collections unlock against it over time.
            if (totalVestingAmount != 0) totalVestingAmountOf[hook][token] += totalVestingAmount;

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Claim all past reward rounds for one token ID into one fresh vesting entry.
    /// @param ctx The claim-round context.
    /// @param tokenId The encoded staker address to claim for.
    /// @param token The reward token to claim.
    /// @return tokenAmount The amount added to vesting.
    function _claimPastRewardsForTokenId(
        JBClaimContext memory ctx,
        uint256 tokenId,
        IERC20 token
    )
        internal
        returns (uint256 tokenAmount)
    {
        // Load this staker's cursor for the reward token. All earlier rounds have already been settled.
        uint256 nextClaimRound = nextClaimRoundOf[ctx.hook][tokenId][token];

        // If the cursor is already past the last completed round, this staker is current.
        if (nextClaimRound > ctx.lastClaimableRound) return 0;

        // Sum this staker's pro-rata share from every unclaimed completed reward round.
        tokenAmount = _claimRewardsFor({
            hook: ctx.hook,
            tokenId: tokenId,
            token: token,
            firstRound: nextClaimRound,
            lastRound: ctx.lastClaimableRound
        });

        // Advance the cursor even when the amount is zero, so empty or zero-stake rounds are not rescanned forever.
        nextClaimRoundOf[ctx.hook][tokenId][token] = ctx.lastClaimableRound + 1;
        if (tokenAmount == 0) return 0;

        // All accumulated past rewards start a single fresh vesting schedule at the claim round.
        vestingDataOf[ctx.hook][tokenId][token].push(
            JBVestingData({releaseRound: ctx.vestingReleaseRound, amount: tokenAmount, shareClaimed: 0})
        );

        emit Claimed({
            hook: ctx.hook,
            tokenId: tokenId,
            token: token,
            amount: tokenAmount,
            vestingReleaseRound: ctx.vestingReleaseRound,
            caller: msg.sender
        });
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Claim a staker's unclaimed rewards across a range of historical reward rounds.
    /// @param hook The IVotes token whose stakers are claiming.
    /// @param tokenId The encoded staker address.
    /// @param token The reward token.
    /// @param firstRound The first reward round to include.
    /// @param lastRound The last reward round to include.
    /// @return tokenAmount The cumulative unclaimed reward amount.
    function _claimRewardsFor(
        address hook,
        uint256 tokenId,
        IERC20 token,
        uint256 firstRound,
        uint256 lastRound
    )
        internal
        returns (uint256 tokenAmount)
    {
        // Walk every unclaimed historical round. The caller bounds this to completed rounds only.
        for (uint256 rewardRoundNumber = firstRound; rewardRoundNumber <= lastRound;) {
            // Load this round's reward data for the hook and reward token.
            JBRewardRoundData storage rewardRound = rewardRoundOf[hook][token][rewardRoundNumber];

            // Skip rounds that never received funding.
            if (rewardRound.amount != 0) {
                // Expired rounds can no longer be claimed; burn their unclaimed remainder instead.
                if (_rewardRoundExpired(rewardRound)) {
                    _burnExpiredRewardRound({hook: hook, token: token, round: rewardRoundNumber});
                } else if (rewardRound.totalStake != 0) {
                    // Use the funding round's snapshot block, not the block at which the staker finally claims.
                    uint256 tokenStakeAmount =
                        _tokenStakeAt({hook: hook, tokenId: tokenId, blockNumber: rewardRound.snapshotBlock});

                    // Zero-vote stakers advance their cursor but do not consume reward inventory.
                    if (tokenStakeAmount != 0) {
                        // The round's reward pot is split pro-rata across checkpointed voting power.
                        uint256 claimAmount =
                            mulDiv({x: rewardRound.amount, y: tokenStakeAmount, denominator: rewardRound.totalStake});

                        // Ignore floor-rounded zero claims to avoid unnecessary storage writes.
                        if (claimAmount != 0) {
                            // Track the portion that has started vesting so expiry burns only the remainder.
                            rewardRound.claimedAmount = _toUint208(uint256(rewardRound.claimedAmount) + claimAmount);

                            // Add this round's vested amount to the staker's cumulative claim.
                            tokenAmount += claimAmount;
                        }
                    }
                }
            }

            unchecked {
                ++rewardRoundNumber;
            }
        }
    }

    /// @notice Check if the account matches the staker address encoded in the tokenId.
    /// @dev tokenId encodes the staker address as `uint256(uint160(stakerAddress))`.
    /// @param hook Unused — access is determined by the tokenId encoding.
    /// @param tokenId The encoded staker address.
    /// @param account The account to check.
    /// @return canClaim True if the account matches the encoded address.
    function _canClaim(address hook, uint256 tokenId, address account) internal pure override returns (bool canClaim) {
        hook; // Silence unused variable warning.
        if (tokenId >> 160 != 0) revert JBTokenDistributor_InvalidTokenId({tokenId: tokenId});
        // The high bits were checked above, so this cast recovers the encoded address.
        // forge-lint: disable-next-line(unsafe-typecast)
        canClaim = address(uint160(tokenId)) == account;
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

    /// @notice The delegated voting power of a staker at the current round's snapshot block.
    /// @dev Uses `IVotes.getPastVotes` for checkpointed lookups. The block number is derived from
    /// `roundSnapshotBlock[currentRound()]`, which is set on first interaction in a round and
    /// consistent with the block used for `_totalStake` in `beginVesting` and `collectVestedRewards`.
    /// @param hook The IVotes-compatible token contract.
    /// @param tokenId The encoded staker address (`uint256(uint160(stakerAddress))`).
    /// @return tokenStakeAmount The delegated voting power at the round's snapshot block.
    function _tokenStake(address hook, uint256 tokenId) internal view override returns (uint256 tokenStakeAmount) {
        tokenStakeAmount =
            _tokenStakeAt({hook: hook, tokenId: tokenId, blockNumber: roundSnapshotBlock[currentRound()]});
    }

    /// @notice The total supply of votes at a specific block.
    /// @dev Uses `IVotes.getPastTotalSupply` for checkpointed lookups.
    /// @param hook The IVotes-compatible token contract.
    /// @param blockNumber The block number to get the total supply at.
    /// @return totalStakedAmount The total supply of votes at the given block.
    function _totalStake(address hook, uint256 blockNumber) internal view override returns (uint256 totalStakedAmount) {
        totalStakedAmount = IVotes(hook).getPastTotalSupply(blockNumber);
    }

    /// @notice Revert unless the caller is authorized to claim each token ID.
    /// @param hook The IVotes token whose stakers are claiming.
    /// @param tokenIds The encoded staker addresses to check.
    function _requireCanClaimTokenIds(address hook, uint256[] calldata tokenIds) internal view override {
        // Each tokenId is an encoded address, so every requested claim must belong to msg.sender.
        for (uint256 i; i < tokenIds.length;) {
            if (!_canClaim({hook: hook, tokenId: tokenIds[i], account: msg.sender})) {
                revert JBDistributor_NoAccess({hook: hook, tokenId: tokenIds[i], account: msg.sender});
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice The delegated voting power of a staker at an explicit snapshot block.
    /// @param hook The IVotes-compatible token contract.
    /// @param tokenId The encoded staker address.
    /// @param blockNumber The historical block to query.
    /// @return tokenStakeAmount The delegated voting power at `blockNumber`.
    function _tokenStakeAt(
        address hook,
        uint256 tokenId,
        uint256 blockNumber
    )
        internal
        view
        returns (uint256 tokenStakeAmount)
    {
        // Reject aliases where high bits would be truncated by the address cast below.
        if (tokenId >> 160 != 0) revert JBTokenDistributor_InvalidTokenId({tokenId: tokenId});

        // The high bits were checked above, so this cast recovers the encoded address.
        // forge-lint: disable-next-line(unsafe-typecast)
        address account = address(uint160(tokenId));

        // Query the staker's delegated votes at the reward round's fixed snapshot block.
        tokenStakeAmount = IVotes(hook).getPastVotes({account: account, timepoint: blockNumber});
    }
}
