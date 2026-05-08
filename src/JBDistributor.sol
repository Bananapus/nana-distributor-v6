// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {IJBDistributor} from "./interfaces/IJBDistributor.sol";
import {JBTokenSnapshotData} from "./structs/JBTokenSnapshotData.sol";
import {JBVestingData} from "./structs/JBVestingData.sol";

/// @notice Abstract base for reward distributors. Manages round-based distribution of ERC-20 tokens (or native ETH)
/// to stakers with linear vesting. Each round, a snapshot is taken of the distributable balance, and stakers can
/// claim their pro-rata share based on their stake weight at the snapshot block. Claimed tokens vest linearly over
/// `vestingRounds` rounds and can be collected as they unlock.
/// @dev Subclasses define how stake is measured (`_tokenStake`, `_totalStake`), who can claim (`_canClaim`), and
/// what "burned" means (`_tokenBurned`). Two concrete implementations exist: `JBTokenDistributor` (IVotes tokens)
/// and `JB721Distributor` (Juicebox 721 NFTs).
abstract contract JBDistributor is IJBDistributor {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when an empty tokenIds array is passed.
    error JBDistributor_EmptyTokenIds(uint256 tokenIdCount);

    /// @notice Thrown when a native ETH transfer fails.
    error JBDistributor_NativeTransferFailed(address beneficiary, uint256 amount);

    /// @notice Thrown when the caller does not have access to the token.
    error JBDistributor_NoAccess(address hook, uint256 tokenId, address account);

    /// @notice Thrown when the round duration is zero.
    error JBDistributor_InvalidRoundDuration(uint256 roundDuration);

    /// @notice Thrown when there is nothing to distribute for a token in the current round.
    error JBDistributor_NothingToDistribute(address hook, address token, uint256 round);

    /// @notice Thrown when unexpected native ETH is sent with an ERC-20 operation.
    error JBDistributor_UnexpectedNativeValue(uint256 msgValue, address token);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The number of shares that represent 100%.
    uint256 public constant MAX_SHARE = 100_000;

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The duration of each round, specified in seconds.
    uint256 public immutable override roundDuration;

    /// @notice The starting timestamp of the distributor.
    uint256 public immutable startingTimestamp;

    /// @notice The number of rounds until tokens are fully vested.
    uint256 public immutable override vestingRounds;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The index within `vestingDataOf` of the latest vest.
    /// @custom:param hook The hook the tokenId belongs to.
    /// @custom:param tokenId The ID of the token to which the vests belong.
    /// @custom:param token The address of the token vested.
    mapping(address hook => mapping(uint256 tokenId => mapping(IERC20 token => uint256))) public latestVestedIndexOf;

    /// @notice The block number recorded as the snapshot point for each round.
    /// @dev Set to `block.number - 1` on first interaction in a round, so that `IVotes.getPastVotes` works.
    mapping(uint256 round => uint256) public override roundSnapshotBlock;

    /// @notice The amount of a token that is currently vesting for a hook's stakers.
    /// @custom:param hook The hook whose stakers are vesting.
    /// @custom:param token The address of the token that is vesting.
    mapping(address hook => mapping(IERC20 token => uint256 amount)) public override totalVestingAmountOf;

    /// @notice All vesting data of a tokenId for any number of vesting tokens.
    /// @custom:param hook The hook the tokenId belongs to.
    /// @custom:param tokenId The ID of the token to which the vests belong.
    /// @custom:param token The address of the token vested.
    mapping(address hook => mapping(uint256 tokenId => mapping(IERC20 token => JBVestingData[]))) public vestingDataOf;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The total accounted balance of each token across all hooks.
    /// @custom:param token The token to check the accounted balance of.
    mapping(IERC20 token => uint256) internal _accountedBalanceOf;

    /// @notice The balance of a token held for a specific hook's stakers.
    /// @custom:param hook The hook whose balance to check.
    /// @custom:param token The token to check the balance of.
    mapping(address hook => mapping(IERC20 token => uint256)) internal _balanceOf;

    /// @notice The snapshot data of the token information for each round.
    /// @custom:param hook The hook the snapshot is for.
    /// @custom:param token The address of the token claimed and vested.
    /// @custom:param round The round to which the data applies.
    mapping(address hook => mapping(IERC20 token => mapping(uint256 round => JBTokenSnapshotData snapshot))) internal
        _snapshotAtRoundOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param roundDuration_ The duration of each round, specified in seconds.
    /// @param vestingRounds_ The number of rounds until tokens are fully vested.
    constructor(uint256 roundDuration_, uint256 vestingRounds_) {
        if (roundDuration_ == 0) revert JBDistributor_InvalidRoundDuration({roundDuration: roundDuration_});
        startingTimestamp = block.timestamp;
        roundDuration = roundDuration_;
        vestingRounds = vestingRounds_;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Snapshot the current round's distributable balance and begin vesting for the specified token IDs.
    /// Each token ID's share is proportional to its stake weight relative to the total stake at the snapshot block.
    /// Vesting completes after `vestingRounds` rounds. Reverts if there's nothing to distribute.
    /// @param hook The hook (IVotes token or 721 hook) whose stakers are vesting.
    /// @param tokenIds The staker token IDs to claim rewards for.
    /// @param tokens The reward tokens to begin vesting.
    function beginVesting(address hook, uint256[] calldata tokenIds, IERC20[] calldata tokens) external override {
        // Revert if no token IDs are provided.
        if (tokenIds.length == 0) revert JBDistributor_EmptyTokenIds({tokenIdCount: tokenIds.length});

        // Keep a reference to the current round.
        uint256 round = currentRound();

        // Ensure the snapshot block is recorded for this round.
        _ensureSnapshotBlock(round);

        // Keep a reference to the total staked amount at the snapshot block.
        uint256 totalStakeAmount = _totalStake({hook: hook, blockNumber: roundSnapshotBlock[round]});

        // Skip vesting when there are no stakers — funds carry over to the next round.
        if (totalStakeAmount == 0) return;

        // Loop through each token for which vesting is beginning.
        for (uint256 i; i < tokens.length;) {
            IERC20 token = tokens[i];

            // Take a snapshot of the token balance if it hasn't been taken already.
            JBTokenSnapshotData memory snapshot = _takeSnapshotOf({hook: hook, token: token});
            uint256 distributable = snapshot.balance - snapshot.vestingAmount;

            // Revert if there is nothing to distribute for this token.
            if (distributable == 0) {
                revert JBDistributor_NothingToDistribute({hook: hook, token: address(token), round: round});
            }

            // Vest each token ID and get the total amount vested.
            uint256 totalVestingAmount = _vestTokenIds({
                hook: hook,
                tokenIds: tokenIds,
                token: token,
                distributable: distributable,
                totalStakeAmount: totalStakeAmount,
                vestingReleaseRound: round + vestingRounds
            });

            unchecked {
                // Store the updated total claimed amount now vesting.
                totalVestingAmountOf[hook][token] += totalVestingAmount;

                ++i;
            }
        }
    }

    /// @notice Directly fund the distributor for a specific hook by pulling tokens from the caller. An alternative
    /// to split-based funding — useful for one-off deposits or external reward sources.
    /// @dev For native ETH, send `msg.value` and pass `IERC20(JBConstants.NATIVE_TOKEN)` as the token. Uses balance
    /// delta to handle fee-on-transfer tokens correctly.
    /// @param hook The hook to fund (determines which staker pool receives the tokens).
    /// @param token The token to fund with.
    /// @param amount The amount to fund (ignored for native ETH — `msg.value` is used instead).
    function fund(address hook, IERC20 token, uint256 amount) external payable override {
        if (address(token) == JBConstants.NATIVE_TOKEN) {
            amount = msg.value;
        } else {
            if (msg.value != 0) {
                revert JBDistributor_UnexpectedNativeValue({msgValue: msg.value, token: address(token)});
            }
            // Use balance delta to handle fee-on-transfer tokens correctly.
            uint256 balanceBefore = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), amount);
            amount = token.balanceOf(address(this)) - balanceBefore;
        }
        _balanceOf[hook][token] += amount;
        _accountedBalanceOf[token] += amount;
    }

    /// @notice Record the snapshot block for the current round (and eagerly for the next round). Callable by anyone —
    /// keepers or frontends can call this early in a round to lock the snapshot block before any claims occur.
    function poke() external override {
        _ensureSnapshotBlock(currentRound());
    }

    /// @notice Release unvested rewards tied to burned tokens. When an NFT is burned, its pending vesting entries
    /// become stranded — this function unlocks them and returns them to the hook's distributable pool (they are NOT
    /// sent to the beneficiary). Anyone can call this for burned tokens.
    /// @param hook The hook whose tokens were burned.
    /// @param tokenIds The IDs of the burned tokens (reverts if any are not actually burned).
    /// @param tokens The reward tokens to release.
    /// @param beneficiary Unused for forfeiture — tokens return to the pool. Kept for interface compatibility.
    function releaseForfeitedRewards(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        external
        override
    {
        // Make sure that all tokens are burned.
        for (uint256 i; i < tokenIds.length;) {
            if (!_tokenBurned({hook: hook, tokenId: tokenIds[i]})) {
                revert JBDistributor_NoAccess({hook: hook, tokenId: tokenIds[i], account: msg.sender});
            }
            unchecked {
                ++i;
            }
        }

        // Unlock the rewards and send them to the beneficiary.
        _unlockRewards({hook: hook, tokenIds: tokenIds, tokens: tokens, beneficiary: beneficiary, ownerClaim: false});
    }

    //*********************************************************************//
    // ----------------------- external views ---------------------------- //
    //*********************************************************************//

    /// @notice The balance of a token held for a specific hook's stakers.
    /// @param hook The hook whose balance to check.
    /// @param token The token to check the balance of.
    function balanceOf(address hook, IERC20 token) external view override returns (uint256) {
        return _balanceOf[hook][token];
    }

    /// @notice Calculate the total amount of a reward token that has been claimed (began vesting) for a given
    /// staker token ID but has not yet been collected. Includes both locked (still vesting) and unlocked amounts.
    /// @param hook The hook the tokenId belongs to.
    /// @param tokenId The ID of the staker token to calculate for.
    /// @param token The reward token to check.
    /// @return tokenAmount The total uncollected amount (vesting + vested-but-uncollected).
    function claimedFor(
        address hook,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        override
        returns (uint256 tokenAmount)
    {
        // Keep a reference to the latest vested index.
        uint256 vestedIndex = latestVestedIndexOf[hook][tokenId][token];

        // Keep a reference to the number of vesting rounds for the tokenId and token.
        uint256 numberOfVestingRounds = vestingDataOf[hook][tokenId][token].length;

        while (vestedIndex < numberOfVestingRounds) {
            // Keep a reference to the vested data being iterated on.
            JBVestingData memory vesting = vestingDataOf[hook][tokenId][token][vestedIndex];

            // Use `original - alreadyPaid` to include rounding dust in the remaining amount.
            tokenAmount += vesting.amount - mulDiv(vesting.amount, vesting.shareClaimed, MAX_SHARE);

            unchecked {
                ++vestedIndex;
            }
        }
    }

    /// @notice Calculate how much of a reward token is currently unlocked and ready to be collected for a given
    /// staker token ID. Only includes the vested portion — excludes amounts still locked in vesting.
    /// @param hook The hook the tokenId belongs to.
    /// @param tokenId The ID of the staker token to calculate for.
    /// @param token The reward token to check.
    /// @return tokenAmount The amount of tokens that can be collected right now via `collectVestedRewards`.
    function collectableFor(
        address hook,
        uint256 tokenId,
        IERC20 token
    )
        external
        view
        override
        returns (uint256 tokenAmount)
    {
        // The round that we are in right now.
        uint256 round = currentRound();

        // Keep a reference to the latest vested index.
        uint256 vestedIndex = latestVestedIndexOf[hook][tokenId][token];

        // Keep a reference to the number of vesting rounds for the tokenId and token.
        uint256 numberOfVestingRounds = vestingDataOf[hook][tokenId][token].length;

        while (vestedIndex < numberOfVestingRounds) {
            uint256 lockedShare;

            // Keep a reference to the vested data being iterated on.
            JBVestingData memory vesting = vestingDataOf[hook][tokenId][token][vestedIndex];

            // Calculate the share amount that is locked.
            if (vesting.releaseRound > round) {
                lockedShare = (vesting.releaseRound - round) * MAX_SHARE / vestingRounds;
            }

            if (lockedShare == 0 && vesting.shareClaimed < MAX_SHARE) {
                // Final unlock: compute remaining as `original - alreadyPaid` to include dust.
                tokenAmount += vesting.amount - mulDiv(vesting.amount, vesting.shareClaimed, MAX_SHARE);
            } else {
                uint256 newShareClaimed = MAX_SHARE - lockedShare;
                if (newShareClaimed > vesting.shareClaimed) {
                    tokenAmount += mulDiv(vesting.amount, newShareClaimed - vesting.shareClaimed, MAX_SHARE);
                }
            }

            unchecked {
                ++vestedIndex;
            }
        }
    }

    /// @notice The snapshot data of the token information for each round.
    /// @param hook The hook the snapshot is for.
    /// @param token The address of the token claimed and vested.
    /// @param round The round to which the data applies.
    function snapshotAtRoundOf(
        address hook,
        IERC20 token,
        uint256 round
    )
        external
        view
        override
        returns (JBTokenSnapshotData memory)
    {
        return _snapshotAtRoundOf[hook][token][round];
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice The number of the current round.
    function currentRound() public view override returns (uint256) {
        return (block.timestamp - startingTimestamp) / roundDuration;
    }

    /// @notice The timestamp at which a round started.
    /// @param round The round to get the start timestamp of.
    function roundStartTimestamp(uint256 round) public view override returns (uint256) {
        return startingTimestamp + roundDuration * round;
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Collect tokens that have vested (partially or fully) and transfer them to the beneficiary. Also
    /// auto-vests for the current round if rewards haven't been claimed yet — so callers don't need to separately
    /// call `beginVesting`. Only the token owner (verified via `_canClaim`) can collect.
    /// @param hook The hook whose stakers are collecting.
    /// @param tokenIds The IDs of the tokens to collect for (caller must own all of them).
    /// @param tokens The reward tokens to collect vested amounts of.
    /// @param beneficiary The recipient of the collected tokens.
    function collectVestedRewards(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary
    )
        public
        override
    {
        // Revert if no token IDs are provided.
        if (tokenIds.length == 0) revert JBDistributor_EmptyTokenIds({tokenIdCount: tokenIds.length});

        // Make sure that all tokens can be claimed by this sender.
        for (uint256 i; i < tokenIds.length;) {
            if (!_canClaim({hook: hook, tokenId: tokenIds[i], account: msg.sender})) {
                revert JBDistributor_NoAccess({hook: hook, tokenId: tokenIds[i], account: msg.sender});
            }
            unchecked {
                ++i;
            }
        }

        // --- Auto-vest for the current round ---
        uint256 round = currentRound();

        // Ensure the snapshot block is recorded for this round.
        _ensureSnapshotBlock(round);

        // Keep a reference to the total staked amount at the snapshot block.
        uint256 totalStakeAmount = _totalStake({hook: hook, blockNumber: roundSnapshotBlock[round]});

        // Loop through each token and auto-vest if there's something distributable.
        for (uint256 i; i < tokens.length;) {
            IERC20 token = tokens[i];

            // Take a snapshot of the token balance if it hasn't been taken already.
            JBTokenSnapshotData memory snapshot = _takeSnapshotOf({hook: hook, token: token});
            uint256 distributable = snapshot.balance - snapshot.vestingAmount;

            // Only auto-vest if there's something to distribute and there's stake.
            if (distributable > 0 && totalStakeAmount > 0) {
                uint256 totalVestingAmount = _vestTokenIds({
                    hook: hook,
                    tokenIds: tokenIds,
                    token: token,
                    distributable: distributable,
                    totalStakeAmount: totalStakeAmount,
                    vestingReleaseRound: round + vestingRounds
                });

                unchecked {
                    totalVestingAmountOf[hook][token] += totalVestingAmount;
                }
            }

            unchecked {
                ++i;
            }
        }

        // Unlock the rewards and send them to the beneficiary.
        _unlockRewards({hook: hook, tokenIds: tokenIds, tokens: tokens, beneficiary: beneficiary, ownerClaim: true});
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Ensures that a snapshot block is recorded for the given round.
    /// @dev Uses `block.number - 1` because `IVotes.getPastVotes` requires a strictly past block.
    /// @param round The round to ensure a snapshot block for.
    function _ensureSnapshotBlock(uint256 round) internal {
        if (roundSnapshotBlock[round] == 0) {
            roundSnapshotBlock[round] = block.number - 1;
            emit RoundSnapshotRecorded({round: round, snapshotBlock: block.number - 1});
        }
        // Eagerly lock the next round's snapshot to prevent first-caller manipulation.
        if (roundSnapshotBlock[round + 1] == 0) {
            roundSnapshotBlock[round + 1] = block.number - 1;
            emit RoundSnapshotRecorded({round: round + 1, snapshotBlock: block.number - 1});
        }
    }

    /// @notice Takes a snapshot of the token balance and vesting amount for the current round.
    /// @param hook The hook to take the snapshot for.
    /// @param token The token address to take a snapshot of.
    /// @return snapshot The snapshot data.
    function _takeSnapshotOf(address hook, IERC20 token) internal returns (JBTokenSnapshotData memory snapshot) {
        // Keep a reference to the current round.
        uint256 round = currentRound();

        // Keep a reference to the token's snapshot.
        snapshot = _snapshotAtRoundOf[hook][token][round];

        // If a snapshot was already taken at this cycle, do not take a new one.
        if (snapshot.balance != 0) return snapshot;

        // Take a snapshot using the hook's tracked balance.
        snapshot =
            JBTokenSnapshotData({balance: _balanceOf[hook][token], vestingAmount: totalVestingAmountOf[hook][token]});

        // Store the snapshot.
        _snapshotAtRoundOf[hook][token][round] = snapshot;

        emit SnapshotCreated({
            hook: hook, round: round, token: token, balance: snapshot.balance, vestingAmount: snapshot.vestingAmount
        });
    }

    /// @notice Unlocks rewards for the given token IDs and tokens, either for collection or forfeiture.
    /// @param hook The hook the tokens belong to.
    /// @param tokenIds The IDs of the tokens to unlock rewards for.
    /// @param tokens The addresses of the tokens to unlock.
    /// @param beneficiary The recipient of the unlocked tokens.
    /// @param ownerClaim Whether this is a claim by the owner (true) or a forfeiture release (false).
    function _unlockRewards(
        address hook,
        uint256[] calldata tokenIds,
        IERC20[] calldata tokens,
        address beneficiary,
        bool ownerClaim
    )
        internal
    {
        uint256 round = currentRound();

        // Loop through each token for which vested rewards are being collected.
        for (uint256 i; i < tokens.length;) {
            IERC20 token = tokens[i];

            // Process all token IDs for this reward token.
            uint256 totalTokenAmount = _unlockTokenIds({hook: hook, tokenIds: tokenIds, token: token, round: round});

            // Perform the transfer.
            if (totalTokenAmount != 0) {
                unchecked {
                    // Update the amount that is left vesting.
                    totalVestingAmountOf[hook][token] -= totalTokenAmount;
                }

                // If this claim is from the owner (or on behalf of the owner).
                if (ownerClaim) {
                    // Decrement the hook's balance and transfer tokens out.
                    _balanceOf[hook][token] -= totalTokenAmount;
                    _accountedBalanceOf[token] -= totalTokenAmount;

                    if (address(token) == JBConstants.NATIVE_TOKEN) {
                        (bool success,) = beneficiary.call{value: totalTokenAmount}("");
                        if (!success) {
                            revert JBDistributor_NativeTransferFailed({
                                beneficiary: beneficiary, amount: totalTokenAmount
                            });
                        }
                    } else {
                        token.safeTransfer(beneficiary, totalTokenAmount);
                    }
                }
                // If forfeiture: _balanceOf is NOT decremented so the forfeited tokens
                // return to the hook's distributable pool for future rounds.
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Unlocks rewards for a set of token IDs for a single reward token.
    /// @param hook The hook the tokens belong to.
    /// @param tokenIds The IDs of the tokens to unlock rewards for.
    /// @param token The reward token to unlock.
    /// @param round The current round.
    /// @return totalTokenAmount The total amount of reward tokens unlocked.
    function _unlockTokenIds(
        address hook,
        uint256[] calldata tokenIds,
        IERC20 token,
        uint256 round
    )
        internal
        returns (uint256 totalTokenAmount)
    {
        for (uint256 j; j < tokenIds.length;) {
            uint256 tokenId = tokenIds[j];

            // Keep a reference to the latest vested index.
            uint256 vestedIndex = latestVestedIndexOf[hook][tokenId][token];

            // Keep a reference to the vesting data array.
            JBVestingData[] storage vestings = vestingDataOf[hook][tokenId][token];
            uint256 numberOfVestingRounds = vestings.length;

            // Keep a reference to a vested index that will be incremented.
            uint256 newLatestVestedIndex = vestedIndex;

            while (vestedIndex < numberOfVestingRounds) {
                // Keep a reference to the vested data being iterated on.
                JBVestingData memory vesting = vestings[vestedIndex];

                // Calculate the share amount that is locked.
                uint256 lockedShare;
                if (vesting.releaseRound > round) {
                    lockedShare = (vesting.releaseRound - round) * MAX_SHARE / vestingRounds;
                }

                uint256 claimAmount;

                if (lockedShare == 0 && vesting.shareClaimed < MAX_SHARE) {
                    // Final unlock: compute remaining amount as `original - alreadyPaid` to force
                    // rounding dust out so nothing is stranded in the entry.
                    claimAmount = vesting.amount - mulDiv(vesting.amount, vesting.shareClaimed, MAX_SHARE);
                } else if (MAX_SHARE - lockedShare > vesting.shareClaimed) {
                    claimAmount = mulDiv(vesting.amount, MAX_SHARE - lockedShare - vesting.shareClaimed, MAX_SHARE);
                }

                if (claimAmount != 0) {
                    vestings[vestedIndex].shareClaimed = MAX_SHARE - lockedShare;
                    totalTokenAmount += claimAmount;
                    emit Collected({
                        hook: hook,
                        tokenId: tokenId,
                        token: token,
                        amount: claimAmount,
                        vestingReleaseRound: vesting.releaseRound
                    });
                }

                unchecked {
                    ++vestedIndex;

                    // Only advance the latest-vested index contiguously past fully exhausted entries.
                    // An entry is exhausted only when its entire share has been claimed (lockedShare == 0).
                    if (
                        lockedShare == 0 && vestings[vestedIndex - 1].shareClaimed == MAX_SHARE
                            && vestedIndex == newLatestVestedIndex + 1
                    ) {
                        ++newLatestVestedIndex;
                    }
                }
            }

            latestVestedIndexOf[hook][tokenId][token] = newLatestVestedIndex;

            unchecked {
                ++j;
            }
        }
    }

    /// @notice Vests each token ID for a given reward token and returns the total amount vested.
    /// @dev Silently skips already-vested tokenIds instead of reverting, to support auto-vest.
    /// @param hook The hook whose stakers are vesting.
    /// @param tokenIds The IDs to claim rewards for.
    /// @param token The reward token.
    /// @param distributable The distributable amount for this round.
    /// @param totalStakeAmount The total stake amount.
    /// @param vestingReleaseRound The round at which vesting will be released.
    /// @return totalVestingAmount The total amount that began vesting.
    function _vestTokenIds(
        address hook,
        uint256[] calldata tokenIds,
        IERC20 token,
        uint256 distributable,
        uint256 totalStakeAmount,
        uint256 vestingReleaseRound
    )
        internal
        virtual
        returns (uint256 totalVestingAmount)
    {
        for (uint256 j; j < tokenIds.length;) {
            uint256 tokenId = tokenIds[j];

            // Skip burned tokens — they are excluded from _totalStake, so including them would overbook vesting.
            if (_tokenBurned({hook: hook, tokenId: tokenId})) {
                unchecked {
                    ++j;
                }
                continue;
            }

            // Keep a reference to the vesting data for this hook/tokenId/token.
            JBVestingData[] storage vestings = vestingDataOf[hook][tokenId][token];

            // Skip if this token has already been vested for this round (same releaseRound).
            uint256 numVesting = vestings.length;
            if (numVesting != 0 && vestings[numVesting - 1].releaseRound == vestingReleaseRound) {
                unchecked {
                    ++j;
                }
                continue;
            }

            // Keep a reference to the amount of tokens being claimed.
            uint256 tokenAmount = mulDiv(distributable, _tokenStake({hook: hook, tokenId: tokenId}), totalStakeAmount);

            // Add to the list of vesting data.
            vestings.push(JBVestingData({releaseRound: vestingReleaseRound, amount: tokenAmount, shareClaimed: 0}));

            emit Claimed({
                hook: hook,
                tokenId: tokenId,
                token: token,
                amount: tokenAmount,
                vestingReleaseRound: vestingReleaseRound
            });

            unchecked {
                totalVestingAmount += tokenAmount;
                ++j;
            }
        }
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice Check whether an account is authorized to collect vested rewards for the given token ID. For 721
    /// distributors this is ownership; for token distributors this is address-encoding match.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The ID of the token to check.
    /// @param account The account to check authorization for.
    /// @return canClaim True if the account can collect rewards for this token ID.
    function _canClaim(address hook, uint256 tokenId, address account) internal view virtual returns (bool canClaim);

    /// @notice Check whether a staker token has been burned. Burned tokens are excluded from stake calculations
    /// and their unvested rewards can be released via `releaseForfeitedRewards`.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The token ID to check.
    /// @return tokenWasBurned True if the token has been burned.
    function _tokenBurned(address hook, uint256 tokenId) internal view virtual returns (bool tokenWasBurned);

    /// @notice The stake weight of a specific token ID, used to calculate its pro-rata share of distributions.
    /// For 721 distributors this is the tier's voting units; for token distributors this is delegated voting power.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The ID of the token to get the stake weight of.
    /// @return tokenStakeAmount The stake weight represented by this token ID.
    function _tokenStake(address hook, uint256 tokenId) internal view virtual returns (uint256 tokenStakeAmount);

    /// @notice The total stake across all token IDs at a given block. Used as the denominator when calculating each
    /// token ID's pro-rata share. For 721 distributors this is `getPastTotalSupply` from the checkpoints module;
    /// for token distributors this is `getPastTotalSupply` from the IVotes token.
    /// @param hook The hook to get the total stake for.
    /// @param blockNumber The block number to query (must be strictly in the past).
    /// @return totalStakedAmount The total stake at the given block.
    function _totalStake(address hook, uint256 blockNumber) internal view virtual returns (uint256 totalStakedAmount);
}
