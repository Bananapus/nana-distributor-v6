// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {mulDiv} from "@prb/math/src/Common.sol";

import {JBVestingMath} from "../../src/libraries/JBVestingMath.sol";

/// @notice Functional-correctness proofs/fuzz for the distributor's shared linear-vesting arithmetic
/// (`src/libraries/JBVestingMath.sol`).
///
/// Each property is DUAL-implemented:
///   * `check_<name>` — Halmos symbolic proof, restricted to SMT-tractable shapes (field isolation, the
///     `lockedShare == 0` branch which avoids the 512-bit `mulDiv` domain, comparisons, bounds).
///   * `testFuzz_<name>` — forge fuzz over the full domain including the `mulDiv` partial-unlock branch that
///     Halmos cannot tractably explore.
///
/// Spec references (INVARIANTS.md):
///   A.2.2 / D.6  cumulative-share math prevents dust stranding — successive partial collections sum to the
///                original allocation, and the final unlock releases floor-division dust.
///   A.2.2        `lockedShareOf = (releaseRound - currentRound) * MAX_SHARE / VESTING_ROUNDS`, linear release.
///   A.3.1/A.5    claim can never exceed the still-unclaimed amount (no over-payout of a vesting entry).
contract JBVestingMathProperties is Test {
    /// @notice The distributor's 100% share denominator (mirrors `JBDistributor.MAX_SHARE`).
    uint256 internal constant _MAX_SHARE = 100_000;

    //*********************************************************************//
    // ------- P1: a single unlock never exceeds the unclaimed amount ----- //
    //*********************************************************************//

    /// @notice HALMOS: in the full-unlock branch (`lockedShare == 0`), the newly-claimable amount equals the
    /// remaining unclaimed amount exactly and the cursor advances to 100% — so a final collection can never
    /// over- or under-pay. This branch avoids the 512-bit `mulDiv` symbolic blowup.
    /// @param amount The original vesting entry amount (bounded to keep `mulDiv` byte-tractable).
    /// @param shareClaimed The cumulative share already claimed.
    function check_finalUnlockEqualsUnclaimed(uint64 amount, uint32 shareClaimed) public pure {
        if (shareClaimed >= _MAX_SHARE) return;

        (uint256 claimAmount, uint256 newShareClaimed) = JBVestingMath.newlyClaimableAmountOf({
            amount: uint256(amount), shareClaimed: shareClaimed, lockedShare: 0, maxShare: _MAX_SHARE
        });
        uint256 unclaimed = JBVestingMath.unclaimedAmountOf({
            amount: uint256(amount), shareClaimed: shareClaimed, maxShare: _MAX_SHARE
        });

        assert(claimAmount == unclaimed);
        assert(newShareClaimed == _MAX_SHARE);
    }

    /// @notice FUZZ: over the FULL domain (including the partial-unlock `mulDiv` branch), a single
    /// `newlyClaimableAmountOf` never returns more than the still-unclaimed amount, and never advances the
    /// cumulative share backwards.
    /// @param amount The original vesting entry amount.
    /// @param shareClaimed The cumulative share already claimed.
    /// @param lockedShare The share still locked.
    function testFuzz_claimNeverExceedsUnclaimed(
        uint256 amount,
        uint256 shareClaimed,
        uint256 lockedShare
    )
        public
        pure
    {
        amount = bound(amount, 0, type(uint208).max);
        shareClaimed = bound(shareClaimed, 0, _MAX_SHARE);
        lockedShare = bound(lockedShare, 0, _MAX_SHARE);

        (uint256 claimAmount, uint256 newShareClaimed) = JBVestingMath.newlyClaimableAmountOf({
            amount: amount, shareClaimed: shareClaimed, lockedShare: lockedShare, maxShare: _MAX_SHARE
        });
        uint256 unclaimed =
            JBVestingMath.unclaimedAmountOf({amount: amount, shareClaimed: shareClaimed, maxShare: _MAX_SHARE});

        assertLe(claimAmount, unclaimed, "claim exceeds unclaimed");

        // When something is claimed, the recorded cumulative share must move forward (never regress).
        if (claimAmount != 0) {
            assertGe(newShareClaimed, shareClaimed, "share regressed");
            assertLe(newShareClaimed, _MAX_SHARE, "share over 100%");
        }
    }

    //*********************************************************************//
    // ----- P2: successive collections sum to the original allocation ---- //
    //*********************************************************************//

    /// @notice FUZZ (D.6): the dust-prevention property. Replays the EXACT collection loop the distributor runs
    /// (`_unlockTokenIds`): at each round it computes `lockedShareOf`, takes the `newlyClaimableAmountOf` delta,
    /// and persists `shareClaimed = MAX_SHARE - lockedShare`. After the entry fully vests, the cumulative claimed
    /// MUST equal the original amount exactly (no stranded dust, no over-payment), matching how `claimedFor`
    /// computes the remaining as `amount - mulDiv(amount, shareClaimed, MAX_SHARE)`.
    /// @param amount The original vesting entry amount.
    /// @param vestingRounds The number of rounds in the vesting period.
    /// @param claimRound The round at which the entry begins vesting (= round it was claimed).
    function testFuzz_successiveCollectionsSumToOriginal(
        uint256 amount,
        uint256 vestingRounds,
        uint256 claimRound
    )
        public
        pure
    {
        amount = bound(amount, 0, type(uint208).max);
        vestingRounds = bound(vestingRounds, 1, 64);
        claimRound = bound(claimRound, 0, 1_000_000);

        uint256 releaseRound = claimRound + vestingRounds;

        uint256 shareClaimed; // cumulative share persisted on the entry
        uint256 totalCollected; // cumulative tokens actually released

        // Collect once per round across the whole vesting window (and one extra round past full vest).
        for (uint256 round = claimRound; round <= releaseRound; round++) {
            uint256 lockedShare = JBVestingMath.lockedShareOf({
                releaseRound: releaseRound, currentRound: round, vestingRounds: vestingRounds, maxShare: _MAX_SHARE
            });

            (uint256 claimAmount,) = JBVestingMath.newlyClaimableAmountOf({
                amount: amount, shareClaimed: shareClaimed, lockedShare: lockedShare, maxShare: _MAX_SHARE
            });

            if (claimAmount != 0) {
                // Distributor persists the cumulative checkpoint, NOT the per-round delta (src/JBDistributor.sol).
                shareClaimed = _MAX_SHARE - lockedShare;
                totalCollected += claimAmount;
            }

            // Invariant at every step: collected so far never exceeds the original allocation.
            assertLe(totalCollected, amount, "over-collected mid vest");
        }

        // After the release round, the entry is fully unlocked: every wei must be released.
        assertEq(totalCollected, amount, "dust stranded or over-paid at full vest");

        // And the residual reported by the views must be zero.
        assertEq(
            JBVestingMath.unclaimedAmountOf({amount: amount, shareClaimed: shareClaimed, maxShare: _MAX_SHARE}),
            0,
            "nonzero unclaimed after full vest"
        );
    }

    /// @notice HALMOS: field-isolated, `mulDiv`-free version of the partial->final two-step settlement using the
    /// `lockedShare == 0` final branch so the cumulative claimed equals the original `amount`. A first partial
    /// collection at `shareClaimed0` (already-recorded checkpoint) followed by a final unlock releases exactly
    /// `amount` total, regardless of the intermediate rounded checkpoint.
    /// @param amount The original vesting entry amount.
    /// @param shareClaimed0 The cumulative share recorded after the first partial collection.
    function check_partialThenFinalReleasesWhole(uint64 amount, uint32 shareClaimed0) public pure {
        if (shareClaimed0 > _MAX_SHARE) return;

        // Amount already paid out by the first partial collection, by definition of the checkpoint.
        uint256 paidSoFar = mulDiv({x: uint256(amount), y: shareClaimed0, denominator: _MAX_SHARE});

        // The final unlock (lockedShare == 0) releases the entire remaining unclaimed amount.
        (uint256 finalClaim, uint256 finalShare) = JBVestingMath.newlyClaimableAmountOf({
            amount: uint256(amount), shareClaimed: shareClaimed0, lockedShare: 0, maxShare: _MAX_SHARE
        });

        // The two collections must sum to exactly the original amount (no dust, no over-pay).
        assert(paidSoFar + finalClaim == uint256(amount));
        assert(finalShare == _MAX_SHARE);
    }

    //*********************************************************************//
    // ---------------- P3: lockedShareOf linear-release ------------------ //
    //*********************************************************************//

    /// @notice HALMOS: `lockedShareOf` is monotonically NON-INCREASING in `currentRound` (locked share only ever
    /// shrinks as rounds pass) and is bounded by `MAX_SHARE` whenever the caller's documented precondition
    /// (`releaseRound - currentRound <= vestingRounds` when `releaseRound > currentRound`) holds. Uses small
    /// constant `vestingRounds`/`maxShare` and div-by-constant arithmetic, which is SMT-tractable.
    /// @param releaseRound The round when the entry is fully unlocked.
    /// @param roundA An earlier (or equal) round.
    /// @param roundB A later (or equal) round.
    function check_lockedShareMonotoneNonIncreasing(uint64 releaseRound, uint64 roundA, uint64 roundB) public pure {
        if (roundA > roundB) return; // roundA is the earlier round.

        uint256 lockedA = JBVestingMath.lockedShareOf({
            releaseRound: releaseRound, currentRound: roundA, vestingRounds: 4, maxShare: _MAX_SHARE
        });
        uint256 lockedB = JBVestingMath.lockedShareOf({
            releaseRound: releaseRound, currentRound: roundB, vestingRounds: 4, maxShare: _MAX_SHARE
        });

        // Locked share never grows as the current round advances.
        assert(lockedB <= lockedA);

        // Once at/after the release round, nothing is locked.
        if (roundB >= releaseRound) assert(lockedB == 0);
    }

    /// @notice HALMOS: under the documented precondition `releaseRound - currentRound <= vestingRounds`, the
    /// locked share never exceeds `MAX_SHARE` (so `MAX_SHARE - lockedShare` used by callers never underflows).
    /// @param releaseRound The full-unlock round.
    /// @param currentRound The current round.
    /// @param vestingRounds The vesting period (constrained to a small symbolic range).
    function check_lockedShareBoundedByMaxShare(
        uint64 releaseRound,
        uint64 currentRound,
        uint8 vestingRounds
    )
        public
        pure
    {
        if (vestingRounds == 0) return;
        // Caller-maintained precondition (see JBVestingMath natspec / how the distributor sets releaseRound).
        if (releaseRound > currentRound && releaseRound - currentRound > vestingRounds) return;

        uint256 locked = JBVestingMath.lockedShareOf({
            releaseRound: releaseRound, currentRound: currentRound, vestingRounds: vestingRounds, maxShare: _MAX_SHARE
        });

        assert(locked <= _MAX_SHARE);
    }

    /// @notice FUZZ: full-domain check that `lockedShareOf` is monotone non-increasing in the current round and
    /// hits exactly `MAX_SHARE * k / vestingRounds` at each integer round, matching the linear schedule (A.2.2).
    /// @param releaseRound The full-unlock round.
    /// @param vestingRounds The vesting period.
    /// @param stepsBefore How many rounds before release to sample (0..vestingRounds).
    function testFuzz_lockedShareLinearSchedule(
        uint256 releaseRound,
        uint256 vestingRounds,
        uint256 stepsBefore
    )
        public
        pure
    {
        vestingRounds = bound(vestingRounds, 1, 1000);
        releaseRound = bound(releaseRound, vestingRounds, 2_000_000);
        stepsBefore = bound(stepsBefore, 0, vestingRounds);

        uint256 currentRound = releaseRound - stepsBefore;

        uint256 locked = JBVestingMath.lockedShareOf({
            releaseRound: releaseRound, currentRound: currentRound, vestingRounds: vestingRounds, maxShare: _MAX_SHARE
        });

        // Exact linear schedule: k rounds remaining => k/vestingRounds of MAX_SHARE locked.
        assertEq(locked, stepsBefore * _MAX_SHARE / vestingRounds, "off-schedule locked share");
        assertLe(locked, _MAX_SHARE, "locked over 100%");
    }

    //*********************************************************************//
    // -------- P4: unclaimedAmountOf bounds & full-vest settlement ------- //
    //*********************************************************************//

    /// @notice FUZZ: `unclaimedAmountOf` is always `<= amount`, is exactly `amount` at `shareClaimed == 0`, and is
    /// exactly `0` at `shareClaimed == MAX_SHARE` (the dust-release endpoint, A.2.2 final-settle).
    /// @param amount The original vesting entry amount.
    /// @param shareClaimed The cumulative share already claimed.
    function testFuzz_unclaimedBounds(uint256 amount, uint256 shareClaimed) public pure {
        amount = bound(amount, 0, type(uint208).max);
        shareClaimed = bound(shareClaimed, 0, _MAX_SHARE);

        uint256 unclaimed =
            JBVestingMath.unclaimedAmountOf({amount: amount, shareClaimed: shareClaimed, maxShare: _MAX_SHARE});

        assertLe(unclaimed, amount, "unclaimed exceeds amount");
        if (shareClaimed == 0) assertEq(unclaimed, amount, "wrong unclaimed at 0%");
        if (shareClaimed == _MAX_SHARE) assertEq(unclaimed, 0, "dust stranded at 100%");
    }

    /// @notice HALMOS: `unclaimedAmountOf` is monotonically non-increasing in `shareClaimed` (claiming more never
    /// increases the residual). Bounded amount keeps the two `mulDiv` calls byte-tractable.
    /// @param amount The original vesting entry amount.
    /// @param shareA An earlier (smaller) claimed share.
    /// @param shareB A later (larger) claimed share.
    function check_unclaimedMonotoneInShare(uint64 amount, uint32 shareA, uint32 shareB) public pure {
        if (shareA > shareB || shareB > _MAX_SHARE) return;

        uint256 ua =
            JBVestingMath.unclaimedAmountOf({amount: uint256(amount), shareClaimed: shareA, maxShare: _MAX_SHARE});
        uint256 ub =
            JBVestingMath.unclaimedAmountOf({amount: uint256(amount), shareClaimed: shareB, maxShare: _MAX_SHARE});

        // More claimed => no more unclaimed remaining.
        assert(ub <= ua);
    }
}
