// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {IJBDistributor} from "./interfaces/IJBDistributor.sol";
import {JBTokenSnapshotData} from "./structs/JBTokenSnapshotData.sol";
import {JBVestingData} from "./structs/JBVestingData.sol";

/// @notice A contract managing distributions of tokens to be claimed and vested by stakers of any other token.
abstract contract JBDistributor is IJBDistributor {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    /// @notice Thrown when an empty tokenIds array is passed.
    error JBDistributor_EmptyTokenIds();

    /// @notice Thrown when a native ETH transfer fails.
    error JBDistributor_NativeTransferFailed();

    /// @notice Thrown when the caller does not have access to the token.
    error JBDistributor_NoAccess();

    /// @notice Thrown when there is nothing to distribute for a token in the current round.
    error JBDistributor_NothingToDistribute();

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
    /// @custom:param token The address of the token being vested.
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
    /// @custom:param token The address of the token being vested.
    // slither-disable-next-line uninitialized-state
    mapping(address hook => mapping(uint256 tokenId => mapping(IERC20 token => JBVestingData[]))) public vestingDataOf;

    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice The balance of a token held for a specific hook's stakers.
    /// @custom:param hook The hook whose balance to check.
    /// @custom:param token The token to check the balance of.
    mapping(address hook => mapping(IERC20 token => uint256)) internal _balanceOf;

    /// @notice The snapshot data of the token information for each round.
    /// @custom:param hook The hook the snapshot is for.
    /// @custom:param token The address of the token being claimed and vested.
    /// @custom:param round The round to which the data applies.
    mapping(address hook => mapping(IERC20 token => mapping(uint256 round => JBTokenSnapshotData snapshot))) internal
        _snapshotAtRoundOf;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param roundDuration_ The duration of each round, specified in seconds.
    /// @param vestingRounds_ The number of rounds until tokens are fully vested.
    constructor(uint256 roundDuration_, uint256 vestingRounds_) {
        startingTimestamp = block.timestamp;
        roundDuration = roundDuration_;
        vestingRounds = vestingRounds_;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Claims tokens and begins vesting.
    /// @param hook The hook whose stakers are vesting.
    /// @param tokenIds The IDs to claim rewards for.
    /// @param tokens The tokens to claim.
    function beginVesting(address hook, uint256[] calldata tokenIds, IERC20[] calldata tokens) external override {
        // Revert if no token IDs are provided.
        if (tokenIds.length == 0) revert JBDistributor_EmptyTokenIds();

        // Keep a reference to the current round.
        uint256 round = currentRound();

        // Ensure the snapshot block is recorded for this round.
        _ensureSnapshotBlock(round);

        // Keep a reference to the total staked amount at the snapshot block.
        uint256 totalStakeAmount = _totalStake(hook, roundSnapshotBlock[round]);

        // Skip vesting when there are no stakers — funds carry over to the next round.
        if (totalStakeAmount == 0) return;

        // Loop through each token for which vesting is beginning.
        for (uint256 i; i < tokens.length;) {
            IERC20 token = tokens[i];

            // Take a snapshot of the token balance if it hasn't been taken already.
            JBTokenSnapshotData memory snapshot = _takeSnapshotOf(hook, token);
            uint256 distributable = snapshot.balance - snapshot.vestingAmount;

            // Revert if there is nothing to distribute for this token.
            if (distributable == 0) revert JBDistributor_NothingToDistribute();

            // Vest each token ID and get the total amount vested.
            uint256 totalVestingAmount =
                _vestTokenIds(hook, tokenIds, token, distributable, totalStakeAmount, round + vestingRounds);

            unchecked {
                // Store the updated total claimed amount now vesting.
                totalVestingAmountOf[hook][token] += totalVestingAmount;

                ++i;
            }
        }
    }

    /// @notice Fund the distributor for a specific hook by pulling tokens from the caller.
    /// @dev For native ETH, send `msg.value` and pass `IERC20(JBConstants.NATIVE_TOKEN)` as the token.
    /// @param hook The hook to fund.
    /// @param token The token to fund with.
    /// @param amount The amount to fund.
    function fund(address hook, IERC20 token, uint256 amount) external payable override {
        if (address(token) == JBConstants.NATIVE_TOKEN) {
            amount = msg.value;
        } else {
            // Use balance delta to handle fee-on-transfer tokens correctly.
            uint256 balanceBefore = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), amount);
            amount = token.balanceOf(address(this)) - balanceBefore;
        }
        _balanceOf[hook][token] += amount;
    }

    /// @notice Record the snapshot block for the current round. Callable by anyone (keepers, frontends).
    function poke() external override {
        _ensureSnapshotBlock(currentRound());
    }

    /// @notice Release vested rewards in the case that a token was burned.
    /// @param hook The hook whose tokens were burned.
    /// @param tokenIds The IDs of the burned tokens.
    /// @param tokens The address of the tokens being released.
    /// @param beneficiary The recipient of the released tokens.
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
            if (!_tokenBurned(hook, tokenIds[i])) revert JBDistributor_NoAccess();
            unchecked {
                ++i;
            }
        }

        // Unlock the rewards and send them to the beneficiary.
        _unlockRewards(hook, tokenIds, tokens, beneficiary, false);
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

    /// @notice Calculate how much of the token has been claimed for the given tokenId.
    /// @param hook The hook the tokenId belongs to.
    /// @param tokenId The ID of the token to calculate the token amount for.
    /// @param token The address of the token being claimed.
    /// @return tokenAmount The amount of tokens that can be claimed once they have vested.
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

            tokenAmount += mulDiv(vesting.amount, MAX_SHARE - vesting.shareClaimed, MAX_SHARE);

            unchecked {
                ++vestedIndex;
            }
        }
    }

    /// @notice Calculate how much of the token is currently ready to be collected for the given tokenId.
    /// @param hook The hook the tokenId belongs to.
    /// @param tokenId The ID of the token to calculate the token amount for.
    /// @param token The address of the token being claimed.
    /// @return tokenAmount The amount of tokens that can be claimed right now.
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

            tokenAmount += mulDiv(vesting.amount, MAX_SHARE - vesting.shareClaimed - lockedShare, MAX_SHARE);

            unchecked {
                ++vestedIndex;
            }
        }
    }

    /// @notice The snapshot data of the token information for each round.
    /// @param hook The hook the snapshot is for.
    /// @param token The address of the token being claimed and vested.
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

    /// @notice Collect vested tokens. Auto-vests for the current round if not already vested.
    /// @param hook The hook whose stakers are collecting.
    /// @param tokenIds The IDs of the tokens to collect for.
    /// @param tokens The address of the tokens being claimed.
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
        if (tokenIds.length == 0) revert JBDistributor_EmptyTokenIds();

        // Make sure that all tokens can be claimed by this sender.
        for (uint256 i; i < tokenIds.length;) {
            if (!_canClaim(hook, tokenIds[i], msg.sender)) revert JBDistributor_NoAccess();
            unchecked {
                ++i;
            }
        }

        // --- Auto-vest for the current round ---
        uint256 round = currentRound();

        // Ensure the snapshot block is recorded for this round.
        _ensureSnapshotBlock(round);

        // Keep a reference to the total staked amount at the snapshot block.
        uint256 totalStakeAmount = _totalStake(hook, roundSnapshotBlock[round]);

        // Loop through each token and auto-vest if there's something distributable.
        for (uint256 i; i < tokens.length;) {
            IERC20 token = tokens[i];

            // Take a snapshot of the token balance if it hasn't been taken already.
            JBTokenSnapshotData memory snapshot = _takeSnapshotOf(hook, token);
            uint256 distributable = snapshot.balance - snapshot.vestingAmount;

            // Only auto-vest if there's something to distribute and there's stake.
            if (distributable > 0 && totalStakeAmount > 0) {
                uint256 totalVestingAmount =
                    _vestTokenIds(hook, tokenIds, token, distributable, totalStakeAmount, round + vestingRounds);

                unchecked {
                    totalVestingAmountOf[hook][token] += totalVestingAmount;
                }
            }

            unchecked {
                ++i;
            }
        }

        // Unlock the rewards and send them to the beneficiary.
        _unlockRewards(hook, tokenIds, tokens, beneficiary, true);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Ensures that a snapshot block is recorded for the given round.
    /// @dev Uses `block.number - 1` because `IVotes.getPastVotes` requires a strictly past block.
    /// @param round The round to ensure a snapshot block for.
    function _ensureSnapshotBlock(uint256 round) internal {
        // slither-disable-next-line incorrect-equality
        if (roundSnapshotBlock[round] == 0) {
            roundSnapshotBlock[round] = block.number - 1;
            emit RoundSnapshotRecorded(round, block.number - 1);
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

        emit SnapshotCreated(hook, round, token, snapshot.balance, snapshot.vestingAmount);
    }

    /// @notice Unlocks rewards for the given token IDs and tokens, either for collection or forfeiture.
    /// @param hook The hook the tokens belong to.
    /// @param tokenIds The IDs of the tokens to unlock rewards for.
    /// @param tokens The address of the tokens being unlocked.
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
            uint256 totalTokenAmount = _unlockTokenIds(hook, tokenIds, token, round);

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

                    if (address(token) == JBConstants.NATIVE_TOKEN) {
                        // slither-disable-next-line arbitrary-send-eth,reentrancy-eth
                        (bool success,) = beneficiary.call{value: totalTokenAmount}("");
                        if (!success) revert JBDistributor_NativeTransferFailed();
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
    /// @param token The reward token being unlocked.
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
                uint256 lockedShare;

                // Keep a reference to the vested data being iterated on.
                JBVestingData memory vesting = vestings[vestedIndex];

                // Calculate the share amount that is locked.
                if (vesting.releaseRound > round) {
                    lockedShare = (vesting.releaseRound - round) * MAX_SHARE / vestingRounds;
                }

                uint256 claimAmount = mulDiv(vesting.amount, MAX_SHARE - vesting.shareClaimed - lockedShare, MAX_SHARE);

                // Update to reflect the amount claimed.
                vestings[vestedIndex].shareClaimed = MAX_SHARE - lockedShare;

                if (claimAmount != 0) {
                    totalTokenAmount += claimAmount;
                    emit Collected(hook, tokenId, token, claimAmount, vesting.releaseRound);
                }

                unchecked {
                    ++vestedIndex;

                    // Only advance the latest-vested index contiguously past fully exhausted entries.
                    // slither-disable-next-line incorrect-equality
                    if (lockedShare == 0 && vestedIndex == newLatestVestedIndex + 1) {
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
        returns (uint256 totalVestingAmount)
    {
        for (uint256 j; j < tokenIds.length;) {
            uint256 tokenId = tokenIds[j];

            // Skip burned tokens — they are excluded from _totalStake, so including them would overbook vesting.
            if (_tokenBurned(hook, tokenId)) {
                unchecked {
                    ++j;
                }
                continue;
            }

            // Keep a reference to the vesting data for this hook/tokenId/token.
            JBVestingData[] storage vestings = vestingDataOf[hook][tokenId][token];

            // Skip if this token has already been vested for this round (same releaseRound).
            uint256 numVesting = vestings.length;
            // slither-disable-next-line incorrect-equality
            if (numVesting != 0 && vestings[numVesting - 1].releaseRound == vestingReleaseRound) {
                unchecked {
                    ++j;
                }
                continue;
            }

            // Keep a reference to the amount of tokens being claimed.
            uint256 tokenAmount = mulDiv(distributable, _tokenStake(hook, tokenId), totalStakeAmount);

            // Add to the list of vesting data.
            vestings.push(JBVestingData({releaseRound: vestingReleaseRound, amount: tokenAmount, shareClaimed: 0}));

            emit Claimed(hook, tokenId, token, tokenAmount, vestingReleaseRound);

            unchecked {
                totalVestingAmount += tokenAmount;
                ++j;
            }
        }
    }

    //*********************************************************************//
    // ----------------------- internal views ---------------------------- //
    //*********************************************************************//

    /// @notice A flag indicating if an account can currently claim their tokens.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The ID of the token to check.
    /// @param account The account to check if it can claim.
    /// @return canClaim A flag indicating if claiming is allowed.
    function _canClaim(address hook, uint256 tokenId, address account) internal view virtual returns (bool canClaim);

    /// @notice Checks if the given token was burned or not.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The tokenId to check.
    /// @return tokenWasBurned A boolean that is true if the token was burned.
    function _tokenBurned(address hook, uint256 tokenId) internal view virtual returns (bool tokenWasBurned);

    /// @notice The amount of tokens staked for the given token ID.
    /// @param hook The hook the token belongs to.
    /// @param tokenId The ID of the token to get the staked value of.
    /// @return tokenStakeAmount The amount of staked tokens that is being represented by the token.
    function _tokenStake(address hook, uint256 tokenId) internal view virtual returns (uint256 tokenStakeAmount);

    /// @notice The total amount staked at the given block.
    /// @param hook The hook to get the total stake for.
    /// @param blockNumber The block number to get the total staked amount at.
    /// @return totalStakedAmount The total amount staked at a block number.
    function _totalStake(address hook, uint256 blockNumber) internal view virtual returns (uint256 totalStakedAmount);
}
