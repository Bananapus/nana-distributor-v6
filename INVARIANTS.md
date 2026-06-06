# Invariants of `nana-distributor-v6`

Scope: the three production contracts in `src/` — the abstract base `JBDistributor` and its two concrete specializations `JBTokenDistributor` (IVotes ERC-20 staker) and `JB721Distributor` (Juicebox 721 NFT staker) — plus the pure helper library `src/libraries/JBVestingMath.sol`. A distributor accumulates reward tokens per-hook, snapshots the staker set once per round at a strictly-past block, allocates the snapshotted pot pro-rata by stake, and vests each staker's share linearly over `VESTING_ROUNDS` rounds. Reward tokens that are **revnet** project tokens (owned by the configured `REVOwner`) can additionally be used as collateral for a distributor-held `REVLoans` loan, deferring collection until repayment.

This file is the per-repo scoped invariants doc. The protocol-wide guarantees for the seven deployed revnets live in [`../INVARIANTS.md`](../INVARIANTS.md); section C.19 there summarizes this repo from the protocol's perspective.

---

## Section A — Guarantees to stakers

## A.1 Snapshot fairness

- **A.1.1 Round snapshot is `block.number - 1`, locked on first interaction.** `_ensureSnapshotBlockFor` writes `roundSnapshotBlock[round] = block.number - 1` once per round and never overwrites it (`src/JBDistributor.sol:1143-1150`). The strictly-past block is required by both `IVotes.getPastVotes` and `IJB721Checkpoints.ownerOfAt`, and means the first interaction of the round cannot manipulate the eligible staker set.
- **A.1.2 Snapshot is eagerly armed for the next round.** Every snapshot-aware code path also locks `round + 1` via `_ensureSnapshotBlock` (`src/JBDistributor.sol:1132-1136`). This blocks a same-block "mint NFT → poke → claim" sequence from claiming pro-rata in the round in which the staker first existed.
- **A.1.3 `poke()` is permissionless.** Any keeper or frontend can call `poke()` to lock the current round's snapshot block before any pay/claim activity (`src/JBDistributor.sol:331-333`). Locking earlier is always equal or better for stakers; locking later cannot exceed the prevailing `block.number - 1`.
- **A.1.4 Per-round reward pots keep a fixed snapshot.** When `_recordRewardRound` first credits a round, it writes `snapshotBlock`, `claimDeadline`, and `totalStake` into `rewardRoundOf[hook][groupId][token][round]`. Subsequent funding in the same round increases `.amount` but never re-snapshots stake, block, or denominator. Token rounds seal `IJBActiveVotes.getPastTotalActiveVotes` at first credit; 721 rounds seal their checkpointed active stake at first credit.
- **A.1.5 Token-distributor stake is delegated voting power at the snapshot block.** Token claimants use `IVotes.getPastVotes` for the encoded staker address. Token rounds use `IJBActiveVotes.getPastTotalActiveVotes` as the denominator, so undelegated balances do not share the round. `CLAIM_DURATION` only controls expiry.
- **A.1.6 721 stake is capped by snapshot owner-tier active votes.** `JB721Distributor._tokenStake` queries the hook's checkpoints module: `_snapshotOwnerOf` returns the owner-at-snapshot (or zero), and `getPastAccountTierActiveVotes(owner, tierId, snapshotBlock)` gates that owner's effective claim for the token's tier. Late mints, post-snapshot transfers, and owners without active units in the token's tier receive zero.
- **A.1.7 Per-owner, per-tier active-vote cap across each NFT reward group.** When an owner holds multiple NFTs in the same tier, `_claimRewardRoundForTokenId` uses owner-tier `consumed[]` accounting to cap the aggregate claim at the owner's snapshot active units for that tier, persisted into `_consumedTierVotesOf[hook][groupId][token][round][owner][tierId]` across calls. The cap is group-scoped, so all-tiers rewards and each tier-scoped group can be claimed independently while each group enforces the same owner-tier budget.

## A.2 Allocation and vesting math

- **A.2.1 Pro-rata allocation by stake.** Each token ID's share is `mulDiv(distributable, tokenStake, totalStake)`, computed in each child distributor's lazy past-round claim (`src/JBTokenDistributor.sol:295`, `src/JB721Distributor.sol:422`).
- **A.2.2 Linear vesting via cumulative-share math.** `lockedShareOf` returns `(releaseRound - currentRound) * MAX_SHARE / VESTING_ROUNDS`; `newlyClaimableAmountOf` computes the unlock delta as the difference of two `mulDiv` rounds against the cumulative `shareClaimed`, not the incremental share, so floor-rounding dust cannot be stranded over partial collections (`src/libraries/JBVestingMath.sol:16-55`, `src/JBDistributor.sol:432-446, 1272-1293`). The final `unclaimedAmountOf` settles the last unlock as `amount - mulDiv(amount, shareClaimed, MAX_SHARE)` which releases dust at full vest (`src/libraries/JBVestingMath.sol:63-73`).
- **A.2.3 `MAX_SHARE = 100_000`.** The denominator constant for vesting share arithmetic (`src/JBDistributor.sol:105`).
- **A.2.4 Vesting-entry boundaries are append-only.** `vestingDataOf` is `push`-only during lazy past-round claims (`src/JBTokenDistributor.sol:241`, `src/JB721Distributor.sol:293`); `latestVestedIndexOf` only ever advances forward over contiguously-exhausted entries (`src/JBDistributor.sol:1303-1316`).
- **A.2.5 Empty resolved rounds advance the lazy-claim cursor.** During lazy claim the cursor (`nextClaimRoundOf`) advances past zero-amount rounds and resolved zero-stake rounds so they are not rescanned forever. Active-voter token rounds with a nonzero recorded denominator can be materialized before or after the deadline; zero-active rounds recycle after the deadline.
- **A.2.6 Burned tokens are excluded.** In the 721 lazy-claim path, `_claimRewardRoundForTokenId` resolves the snapshot owner via `_snapshotOwnerOf` and returns zero when no historical owner exists — a burned NFT has no `ownerOfAt` at the snapshot block (`src/JB721Distributor.sol:387-388`). So a burned NFT can never overbook vesting against the snapshot-locked total stake (which excludes burned units).

## A.3 Collection authorization

- **A.3.1 `beginVesting` is permissionless.** The shared base validates token IDs, then materializes past rewards into
  vesting entries. No reward tokens leave the distributor, so a third party can only start another holder's vesting
  clock.
- **A.3.2 `collectVestedRewards` preserves beneficiary control.** `_requireCanCollectTo` lets an authorized holder
  route rewards to any beneficiary. A helper that does not control a token ID can collect only to that token ID's
  canonical beneficiary, as returned by `_claimBeneficiaryOf`.
- **A.3.3 Canonical beneficiaries are distributor-specific.** For `JBTokenDistributor`, the beneficiary is the address
  encoded in `tokenId`, and high-bit aliasing reverts. For `JB721Distributor`, the beneficiary is
  `IERC721.ownerOf(tokenId)`, so burned or nonexistent NFTs cannot be helper-collected.
- **A.3.4 NFT batches must be strictly increasing.** `JB721Distributor._validateTokenIds` and
  `JB721Distributor._requireCanClaimTokenIds` both revert `JB721Distributor_TokenIdsNotIncreasing` if `tokenIds` is
  not strictly ascending, so the same NFT cannot appear twice in one call.
- **A.3.5 Loan and redirect authority stays holder-gated.** `borrowAgainstVesting` and owner-directed custom
  beneficiaries still call `_requireCanClaimTokenIds`; a third party cannot borrow against someone else's vesting
  rewards or redirect them away from the canonical beneficiary.

## A.4 Loan-against-vesting protections

- **A.4.1 Collection blocked while a loan is outstanding.** `_unlockTokenIds` reverts via `_requireNoActiveVestingLoan` if `activeVestingLoanIdOf[hook][groupId][tokenId][token] != 0` (`src/JBDistributor.sol:1256, 1386-1393`). `collectableFor` returns 0 under the same condition (`src/JBDistributor.sol:414`).
- **A.4.2 One vesting position, one outstanding loan.** `_borrowAgainstVesting` reverts `JBDistributor_VestingLoanOutstanding` if an active loan already exists for the `(hook, tokenId, token)` triple (`src/JBDistributor.sol:682-687`).
- **A.4.3 Same-position reentrancy lock.** Before the external `REV_LOANS.borrowFrom` call (which burns collateral and may trigger callbacks), the active loan ID is set to the sentinel `_PENDING_VESTING_LOAN_ID = type(uint256).max`; the real loan ID is written on return (`src/JBDistributor.sol:709-718`).
- **A.4.4 Loan collateral is exactly the unclaimed vesting amount at borrow time.** `collateralCount = _unclaimedVestingAmountOf({hook, tokenId, token})` after bringing the staker current via `_claimPastRewards` (`src/JBDistributor.sol:690-693`).
- **A.4.5 Borrow-time vesting boundary is recorded.** `vestingDataCount` snapshots the length of the staker's `vestingDataOf` array at borrow time, so liquidation write-off cannot consume vesting entries that accrued *after* the loan was opened (`src/JBDistributor.sol:696, 910-919`).
- **A.4.6 Repay restores the exact collateral count.** `_restoreVestingCollateral` reverts `JBDistributor_InsufficientRepaidCollateral` if the balance delta after `REV_LOANS.repayLoan` is less than the original collateral count (`src/JBDistributor.sol:858-862`); excess (from a same-token source fee) is refunded to the repayer (`src/JBDistributor.sol:875-878`).
- **A.4.7 Native repay refunds overpayment after the loan is settled.** On the native source-token path, `_repayLoanSource` reports the overpayment (`msg.value - repayBorrowAmount`) instead of sending it. `repayVestingLoan` runs `_restoreVestingCollateral` first — deleting `_vestingLoanOf[loanId]` and decrementing `totalLoanedVestingAmountOf` — and only then refunds `msg.sender` via a `call` (native send failures revert). Following checks-effects-interactions, a re-entrant `writeOffLiquidatedVestingLoan(loanId)` during the refund finds the loan already gone (`JBDistributor_NoVestingLoan`), so the loaned-vesting inventory cannot be decremented twice for one loan (`src/JBDistributor.sol`, `repayVestingLoan` / `_repayLoanSource`).
- **A.4.8 ERC-20 repay credits exactly the amount pulled.** `safeTransferFrom` + balance-delta check reverts `JBDistributor_UnexpectedRepayAmount` if a fee-on-transfer or rebasing token short-credits the repay (`src/JBDistributor.sol:813-819`).
- **A.4.9 Allowance is approved and cleared per repay call.** `forceApprove({REV_LOANS, repayBorrowAmount})` immediately before, and `forceApprove({REV_LOANS, 0})` immediately after, the external `repayLoan` (`src/JBDistributor.sol:822-834`). Tokens that require explicit approval reset (USDT-style) are safe.
- **A.4.10 Repay is permissionless.** Anyone can repay any distributor-held loan; the collateral is always restored to the original token ID's vesting schedule, not the repayer (`src/JBDistributor.sol:582-630`). A third-party repay strictly helps the staker.
- **A.4.11 Write-off requires actual revnet liquidation.** `writeOffLiquidatedVestingLoan` reverts `JBDistributor_VestingLoanNotLiquidated` unless `REV_LOANS.loanOf(loanId).createdAt == 0` (`src/JBDistributor.sol:643-646`). A live loan must be repaid, not written off.
- **A.4.12 Loans only against revnet reward tokens.** `_revnetIdOf` reverts `JBDistributor_NotRevnetRewardToken` unless the reward token is registered as a JB project token AND that project is owned by the configured `REV_OWNER` (`src/JBDistributor.sol:1101-1109`).
- **A.4.13 Loans require non-zero `VESTING_ROUNDS`.** Borrow reverts `JBDistributor_VestingLoansDisabled` when `VESTING_ROUNDS == 0` (`src/JBDistributor.sol:554`).
- **A.4.14 Constructor grants `REVLoans` only `BURN_TOKENS` permission, only when configured.** The constructor wildcards `BURN_TOKENS` for the trusted `revLoans` operator (`src/JBDistributor.sol:237-248`); no other permission is delegated. If `revLoans == address(0)`, no permission is granted and `borrowAgainstVesting` reverts `JBDistributor_RevnetLoansNotConfigured` (`src/JBDistributor.sol:557`).

## A.5 Expiry and recycling — dust prevention

- **A.5.1 `recycleExpiredRewards` recycles eligible expired inventory into the current round.** Permissionless. Only acts on rounds whose `claimDeadline != 0` and `block.timestamp >= claimDeadline`. `claimedAmount` is set to `amount` BEFORE the new round write, so the round cannot double-recycle. In `JBTokenDistributor`, active-voter rounds with nonzero active votes recycle zero and remain claimable by snapshot voters.
- **A.5.2 `CLAIM_DURATION == 0` makes rewards never expire.** `_claimDeadlineFor` returns 0 (`src/JBDistributor.sol:1155-1161`) and `_rewardRoundExpired` returns false unconditionally (`src/JBDistributor.sol:1166-1173`).
- **A.5.3 Expired rounds short-circuit during lazy claim only when they are recyclable.** `JBTokenDistributor._claimRewardsFor` recycles an expired active-voter round only if its recorded active-vote total is zero; otherwise snapshot voters can still materialize their pro-rata share after the deadline. `JB721Distributor._claimPastRewardsForToken` routes expired unclaimed rounds through `_recycleExpiredRewardRound`.
- **A.5.4 `releaseForfeitedRewards` requires tokenIds actually burned.** Reverts `JBDistributor_NoAccess` unless every requested tokenId returns `_tokenBurned == true` (`src/JBDistributor.sol:341-365`). For `JBTokenDistributor` this always reverts because `_tokenBurned` is hardcoded `false` (`src/JBTokenDistributor.sol:334-338`); only the 721 distributor exposes this path (`src/JB721Distributor.sol:468-474`).
- **A.5.5 Forfeited inventory recycles into the current round, not to the caller.** `_unlockRewards` with `ownerClaim=false` calls `_recordRewardRound` for the unlocked amount instead of transferring; the inventory stays inside the distributor (`src/JBDistributor.sol:1224-1228`). The `beneficiary` argument is intentionally unused on the forfeit path.

## A.6 Tier-scoped reward groups

- **A.6.1 `groupId` keys the reward, vesting, and loan maps.** `rewardRoundOf`, `vestingDataOf`, `latestVestedIndexOf`, `activeVestingLoanIdOf`, and `nextClaimRoundOf` all carry a `groupId` dimension (`src/JBDistributor.sol`, `src/JB721Distributor.sol`); the `JBVestingLoan` struct carries `groupId` as its 2nd member (`src/structs/JBVestingLoan.sol`). In the base, `groupId` is a generic partition key with no tier meaning. The tier concept lives in `JB721Distributor`: `groupId == 0` is the all-tiers group, and a non-zero group is `keccak256(abi.encode(tierIds))` for a strictly-increasing tier set, derived by `JB721Distributor._groupIdFor`, which reverts `JB721Distributor_TierIdsNotIncreasing` on a non-increasing set.
- **A.6.2 Group 0 is the default all-tiers pool.** The plain signatures (`fund`, `beginVesting`, `collectVestedRewards`, `borrowAgainstVesting`, `recycleExpiredRewards`, `releaseForfeitedRewards`, `claimedFor`, `collectableFor`) route through `groupId == 0`. The `tierIds` overloads (on `JB721Distributor` only) add tier-set membership and never write group 0. Both paths enforce the same owner-tier active-vote cap (A.1.7).
- **A.6.3 Tier-scoped denominators use active tier totals.** A tier-scoped round's denominator is the summed `getPastTotalTierActiveVotes(tierId, snapshotBlock)` over the funded tier set. Each eligible NFT must be in the funded tier set and owned at the round snapshot, then its numerator is `min(tier.votingUnits, remaining owner-tier active votes)` using `getPastAccountTierActiveVotes(owner, tierId, snapshotBlock)`.
- **A.6.4 `_consumedTierVotesOf` is group-scoped.** Owner-tier consumed active-vote accounting (`_consumedTierVotesOf[hook][groupId][token][round][owner][tierId]`) is shared by the all-tiers and tier-scoped claim code, but keyed by `groupId` so overlapping reward groups cannot consume each other's budgets.
- **A.6.5 Tier sets are recorded once and queryable.** `_tierIdsOfGroup[hook][groupId]` is written on the group's first funding and exposed via `tierIdsOf(hook, groupId)`; it is empty for group 0.
- **A.6.6 Split funding is group-0 only.** `processSplitWith` always records funding under `groupId == 0` — a split cannot carry a tier set. Tier-scoped pots require the explicit `fund(hook, tierIds, token, amount)`.
- **A.6.7 Token distributors are group-agnostic in weight.** `JBTokenDistributor` threads `groupId` only for storage isolation. Token distributors have no tier concept: token rounds use `getPastTotalActiveVotes`, and `CLAIM_DURATION` only controls expiry.

---

## Section B — Operator surface

The distributor has **no global admin and no per-hook operator role**. There is no Ownable, no upgrade hook, no protocol-fee setter, no pause switch. All mutating surface is either:

- holder-gated (`borrowAgainstVesting`, custom-beneficiary collection),
- terminal/controller-gated (`processSplitWith`),
- permissionless settlement (`fund`, `poke`, `beginVesting`, canonical-beneficiary `collectVestedRewards`,
  `recycleExpiredRewards`, `releaseForfeitedRewards`, `repayVestingLoan`, `writeOffLiquidatedVestingLoan`).

The only authority granted at construction is a wildcard `BURN_TOKENS` permission to `REV_LOANS`, gated on `revLoans != address(0)` (A.4.14). The distributor itself never receives a project-scoped permission and never holds a project NFT.

---

## Section C — Per-contract operation inventory

## C.1 `JBDistributor` (abstract base) — `src/JBDistributor.sol`

### Constructor (one-shot)

- **`constructor(controller, revLoans, revOwner, initialRoundDuration, initialVestingRounds, initialClaimDuration)`** — reverts `JBDistributor_InvalidRoundDuration` if `initialRoundDuration == 0`. Stamps `STARTING_TIMESTAMP = block.timestamp`. Grants `BURN_TOKENS` to `revLoans` only when `revLoans != address(0)` (`src/JBDistributor.sol:218-249`).

### Permissionless funding

- **`fund(hook, token, amount) payable`** — anyone. For native, `msg.value` overrides `amount`; for ERC-20, pulls via `safeTransferFrom` and credits the actual balance delta. Reentrancy-guarded by `_acceptingToken` (`src/JBDistributor.sol:294-296, 952-1001`).
  - **Invariants:** `_balanceOf[hook][token]` and `_accountedBalanceOf[token]` increase by exactly the accepted delta; the current round's `rewardRoundOf` pot is sealed with a fixed snapshot block on first credit; reentrancy via the reward token cannot mutate any other accounting path while `_acceptingToken != address(0)`.

### Permissionless settlement

- **`beginVesting(hook, tokenIds, tokens)`** — shared base implementation for both distributors. Reverts `JBDistributor_EmptyTokenIds` if empty, validates token IDs, then calls `_claimPastRewards` to materialize historical reward rounds. Active-voter token rounds with nonzero active votes materialize lazily; resolved empty rounds advance the cursor (A.2.5).
- **`recycleExpiredRewards(hook, token, rounds[]) → amount`** — permissionless (`src/JBDistributor.sol:304-327`). See A.5.1.
- **`releaseForfeitedRewards(hook, tokenIds, tokens, beneficiary)`** — permissionless; requires burned tokenIds (`src/JBDistributor.sol:341-365`). See A.5.4.
- **`poke()`** — permissionless snapshot lock-in (`src/JBDistributor.sol:331-333`). See A.1.3.

### Holder-gated and helper collection

- **`collectVestedRewards(hook, tokenIds, tokens, beneficiary)`** — shared base implementation. Reverts `JBDistributor_EmptyTokenIds` if empty, validates token IDs, applies `_requireCanCollectTo`, materializes past reward rounds via `_claimPastRewards`, then `_unlockRewards(..., ownerClaim: true)` releases the unlocked portion of existing vesting entries to `beneficiary`. Native send failures revert via `JBDistributor_NativeTransferFailed`. See A.3.2.
- **`borrowAgainstVesting(hook, tokenIds, tokens, sourceToken, minBorrowAmount, prepaidFeePercent, beneficiary) → (loanId, collateralCount)`** — only the staker. Requires `tokenIds.length == tokens.length == 1`, `VESTING_ROUNDS != 0`, `REV_LOANS != address(0)`, and the reward token must be a REVOwner-owned revnet project token (`src/JBDistributor.sol:527-576, 673-728`). See A.4.

### Permissionless loan settlement

- **`repayVestingLoan(loanId, maxRepayBorrowAmount) payable → paidOffLoanId`** — anyone (A.4.10). Reverts `JBDistributor_NoVestingLoan` if the loan is not distributor-tracked (`src/JBDistributor.sol:582-630`).
- **`writeOffLiquidatedVestingLoan(loanId) → collateralCount`** — anyone, only after revnet liquidation (A.4.11) (`src/JBDistributor.sol:635-650, 893-945`).

### Hook-overridable internals

- **`_canClaim(hook, tokenId, account) view → bool`** — abstract; subclass-defined ownership check.
- **`_claimBeneficiaryOf(hook, tokenId) view → address`** — abstract; subclass-defined canonical collection
  beneficiary.
- **`_claimPastRewards(hook, tokenIds, tokens)`** — abstract; subclass-defined lazy past-round materialization.
- **`_requireCanClaimTokenIds(hook, tokenIds) view`** — abstract; subclass-defined batch authorization for redirects
  and borrowing.
- **`_tokenBurned(hook, tokenId) view → bool`** — abstract; subclass-defined burn check.
- **`_tokenStake(hook, tokenId) view → uint256`** — abstract; subclass-defined stake weight.
- **`_totalStake(hook, groupId, blockNumber) view → uint256`** — abstract; subclass-defined total at block (721 group 0 = `getPastTotalActiveVotes`, tier-scoped group = summed `getPastTotalTierActiveVotes` over the group's tier set; token distributors ignore `groupId`, returning global supply for non-expiring rounds and active-vote supply for active-voter rounds).
- **`_validateTokenIds(hook, tokenIds) view`** — abstract; subclass-defined batch validation for permissionless
  vesting.

### Views

- **`balanceOf`, `claimedFor`, `collectableFor`, `vestingLoanOf`, `currentRound`, `roundStartTimestamp`** plus public storage mappings (`activeVestingLoanIdOf`, `latestVestedIndexOf`, `roundSnapshotBlock`, `rewardRoundOf`, `totalVestingAmountOf`, `totalLoanedVestingAmountOf`, `vestingDataOf`) and immutables (`CLAIM_DURATION`, `CONTROLLER`, `ROUND_DURATION`, `REV_LOANS`, `REV_OWNER`, `STARTING_TIMESTAMP`, `VESTING_ROUNDS`, `MAX_SHARE`).

## C.2 `JBTokenDistributor` — `src/JBTokenDistributor.sol`

Concrete distributor for IVotes ERC-20 stakers. `tokenId` is the staker address encoded as `uint256(uint160(staker))`; high bits revert (A.3.1).

### Terminal/controller-only

- **`processSplitWith(JBSplitHookContext) payable`** — only `DIRECTORY.isTerminalOf(projectId, msg.sender)` OR `DIRECTORY.controllerOf(projectId) == msg.sender` (`src/JBTokenDistributor.sol:107-145`).
  - **Invariants:** for native, `msg.value == context.amount` exactly (reverts `JBTokenDistributor_NativeAmountMismatch`); for ERC-20, `msg.value == 0` (reverts `JBTokenDistributor_TokenMismatch`) and pull via balance-delta accounting; `hook = context.split.beneficiary` is the IVotes token address.

### Claiming and collection

- `beginVesting` / `collectVestedRewards` are defined once in the base (see C.1). `beginVesting` can be called by any helper for a valid encoded staker slot. `collectVestedRewards` lets helpers collect only to the encoded staker, while the encoded staker can choose any beneficiary. Both dispatch into this distributor's `_claimPastRewards` override, which materializes all completed past rounds (`< currentRound()`) into one fresh vesting entry per token.

### Internals

- `_claimPastRewardsForTokenId` / `_claimRewardsFor` iterate `[firstRound, lastRound]`. Token rounds accumulate `mulDiv(round.amount, pastVotes, round.totalStake)` against the denominator recorded at funding. Expired active-voter rounds with zero active votes recycle.
- `_tokenBurned` is hardcoded `false`; `releaseForfeitedRewards` therefore always reverts on this distributor (A.5.4).
- `_claimBeneficiaryOf` rejects `tokenId >> 160 != 0` to defeat address-alias attacks.

### Views

- `supportsInterface` advertises `IJBTokenDistributor`, `IJBSplitHook`, `IERC165` (`src/JBTokenDistributor.sol:159-162`).
- `nextClaimRoundOf[hook][groupId][tokenId][token]` is the cursor for lazy past-round claims.
- `DIRECTORY` immutable.

### Receive

- **`receive() external payable`** — accepts native ETH (e.g. from payout splits) (`src/JBTokenDistributor.sol:97`).

## C.3 `JB721Distributor` — `src/JB721Distributor.sol`

Concrete distributor for Juicebox 721 NFT stakers. `tokenId` is the NFT token ID; stake is capped by the snapshot owner's active units for the token's tier (A.1.6); the owner-tier cap holds across each reward group (A.1.7).

### Terminal/controller-only

- **`processSplitWith(JBSplitHookContext) payable`** — same auth pattern as C.2 with `JB721Distributor_*` errors (`src/JB721Distributor.sol:125-163`).

### Claiming and collection

- `beginVesting` / `collectVestedRewards` are defined once in the base (see C.1). `beginVesting` can be called by any helper for live, strictly-increasing NFT token IDs. `collectVestedRewards` lets helpers collect only to the current NFT owner, while the current NFT owner can choose any beneficiary. Both dispatch into this distributor's `_claimPastRewards` override, which lazy-claims all completed past rounds with owner-tier active-vote caps.

### Internals

- `_snapshotOwnerOf` uses staticcall to `IJB721Checkpoints.ownerOfAt` so hooks without the checkpoint API fail closed (return zero), making late mints + post-snapshot transfers ineligible rather than reverting the whole batch (`src/JB721Distributor.sol:531-550`).
- `_consumedTierVotesOf[hook][groupId][token][round][owner][tierId]` persists the owner-tier consumed cap across separate calls.
- `_tokenBurned` is a try-catch wrapper around `ownerOf` (`src/JB721Distributor.sol:468-474`).
- `_claimRewardRoundForTokenId` applies the owner-tier active-vote cap during lazy past-round claims via the `consumed[]` scratch array.

### Views

- `supportsInterface` advertises `IJB721Distributor`, `IJBSplitHook`, `IERC165` (`src/JB721Distributor.sol:177-180`).
- `nextClaimRoundOf[hook][groupId][tokenId][token]` cursor and `DIRECTORY` immutable.

### Receive

- **`receive() external payable`** — accepts native ETH (`src/JB721Distributor.sol:113`).

## C.4 `JBVestingMath` — `src/libraries/JBVestingMath.sol`

Pure helpers. No state, no auth. Three functions:

- `lockedShareOf(releaseRound, currentRound, vestingRounds, maxShare) → lockedShare` — linear unlock formula (`src/libraries/JBVestingMath.sol:16-27`).
- `newlyClaimableAmountOf(amount, shareClaimed, lockedShare, maxShare) → (claimAmount, newShareClaimed)` — cumulative-share delta with dust release at full unlock (`src/libraries/JBVestingMath.sol:36-55`).
- `unclaimedAmountOf(amount, shareClaimed, maxShare) → unclaimedAmount` — `amount - paid` so the final unlock releases floor-division dust (`src/libraries/JBVestingMath.sol:63-73`).

---

## Section D — Cross-cutting invariants

- **D.1 Snapshot once per round, pokeable.** `roundSnapshotBlock[round]` is set on first interaction with `block.number - 1` and never overwritten; the next round is eagerly armed alongside (A.1.1, A.1.2). The first interaction of a round cannot redefine the eligible staker set (`src/JBDistributor.sol:1132-1150`).
- **D.2 Per-round pot is locked at first credit.** `JBRewardRoundData.snapshotBlock`, `claimDeadline`, and `totalStake` are stamped on the first non-zero `_recordRewardRound` call for `(hook, token, round)` and never re-stamped, so late mints cannot change the snapshot block or denominator (A.1.4).
- **D.3 Active vesting loan blocks collection.** `_unlockTokenIds` reverts and `collectableFor` returns zero whenever `activeVestingLoanIdOf[hook][groupId][tokenId][token] != 0` (A.4.1).
- **D.4 `_requireNotAcceptingToken` reentrancy guard.** Every state-mutating external entrypoint (`fund`, `beginVesting`, `collectVestedRewards`, `recycleExpiredRewards`, `releaseForfeitedRewards`, `borrowAgainstVesting`, `repayVestingLoan`, `writeOffLiquidatedVestingLoan`, `processSplitWith` via `_acceptErc20FundsFrom`) checks `_acceptingToken == address(0)` (`src/JBDistributor.sol:1377-1380`). A callback-capable reward token cannot mutate claim accounting mid-`balanceOf`/`transferFrom` measurement, and a single inbound transfer cannot net against an outbound transfer to strand funds. The native overpayment refund in `repayVestingLoan` falls outside this ERC-20 guard, so it relies on checks-effects-interactions instead: the loan is fully settled before the refund `call`, so a re-entrant call sees no live loan (A.4.7).
- **D.5 Per-hook reward-pool isolation.** `_balanceOf[hook][token]` and all reward-round / vesting / snapshot data are keyed by `hook`; one hook's stakers can never claim another hook's pool (`src/JBDistributor.sol:148-199`).
- **D.6 Cumulative-share math prevents dust stranding.** `newlyClaimableAmountOf` uses the difference of two `mulDiv` rounds against cumulative shares; `unclaimedAmountOf` releases floor-division dust at full vest (A.2.2). Successive partial collections always sum to the original allocation.
- **D.7 Append-only cursors.** `latestVestedIndexOf` and `nextClaimRoundOf` are monotonically non-decreasing; once a round / vesting entry is exhausted it is never re-walked.
- **D.8 `releaseForfeitedRewards` requires burns.** A non-burned token cannot have its rewards recycled away from the owner (A.5.4).
- **D.9 Borrow → repay restores collateral exactly; liquidation forfeits only collateralized entries.** `vestingDataCount` snapshot at borrow time bounds the write-off range, so vesting that accrued after the loan opened is preserved through liquidation (A.4.5) (`src/JBDistributor.sol:696, 910-919`).
- **D.10 Conservation: `_accountedBalanceOf[token] == Σ hook _balanceOf[hook][token] + Σ hook (totalLoanedVestingAmountOf[hook][token] burned-into-loans)`.** All inventory mutations (`_fund`, `_unlockRewards` for owner-claim, `_borrowAgainstVesting`, `_restoreVestingCollateral`, `_writeOffLiquidatedVestingLoan`) update both sides in lockstep.
- **D.11 No global admin.** The constructor grants only `BURN_TOKENS` to `REV_LOANS` (A.4.14). No protocol fees, no pause, no ownership rotation, no upgrade hook.

---

## Section E — Centralization caveats

- **E.1 No global admin.** There is no `Ownable` on `JBDistributor`, `JBTokenDistributor`, or `JB721Distributor`. The contracts have no upgrade path, no pause switch, no protocol-fee setter, no allowlist. All configuration is immutable at construction.
- **E.2 Cloneable / singleton per-hook design.** A single deployed `JBTokenDistributor` or `JB721Distributor` instance can serve unbounded `hook` addresses. Per-hook state isolation (D.5) means hooks are mutually independent.
- **E.3 Trust in `REVLoans`.** When `revLoans != address(0)`, the constructor wildcards `BURN_TOKENS` to that address (A.4.14). The distributor trusts `REVLoans` to:
  - return the agreed collateral on `repayLoan`,
  - mark `loanOf(loanId).createdAt = 0` on liquidation,
  - never burn more than the supplied `collateralCount`.
  These are properties of the `revnet-core-v6` `REVLoans` contract documented in that repo's INVARIANTS.md. Substituting an adversarial `REV_LOANS` at deploy time would compromise borrow safety.
- **E.4 Trust in `IVotes` / `IJB721Checkpoints` correctness.** `_tokenStake` / `_totalStake` lean on the hook's checkpoint module reporting honest historical voting power. A non-monotone or rewriteable checkpoint would let stakers fabricate snapshot positions. The `IJB721Checkpoints.ownerOfAt` staticcall fails closed (returns address(0)) for hooks that lack the API, which is a soft-fail rather than a revert (A.1.6).
- **E.5 Trust in reward token honesty.** Fee-on-transfer tokens are accounted for via balance-delta (D.4). Rebase/upgradeable tokens that mutate balances out-of-band would break the conservation invariant (D.10); reentrancy via callback tokens is gated by `_requireNotAcceptingToken`.

---

## Section F — Key code references

| Invariant | File:lines |
|---|---|
| A.1.1 snapshot is `block.number - 1`, latched once | `src/JBDistributor.sol:1143-1150` |
| A.1.2 next-round snapshot eagerly armed | `src/JBDistributor.sol:1132-1136` |
| A.1.3 `poke()` permissionless | `src/JBDistributor.sol:331-333` |
| A.1.4 per-round pot sealed on first credit | `src/JBDistributor.sol:1023-1053` |
| A.1.5 token-distributor IVotes lookup | `src/JBTokenDistributor.sol` `_claimRewardRoundFor`, `_claimRewardsFor`, `_totalStake` |
| A.1.6 721 stake capped by snapshot owner-tier active votes | `src/JB721Distributor.sol` `_tokenStake`, `_claimRewardRoundForTokenId` |
| A.1.7 owner-tier active-vote cap across each reward group | `src/JB721Distributor.sol` `_consumedTierVotesOf`, `_claimRewardRoundForTokenId` |
| A.2.1 pro-rata mulDiv | `src/JBTokenDistributor.sol:295`, `src/JB721Distributor.sol:422` |
| A.2.2 cumulative-share math (dust prevention) | `src/libraries/JBVestingMath.sol:36-73`, `src/JBDistributor.sol:432-446, 1272-1293` |
| A.2.4 append-only vesting cursor | `src/JBDistributor.sol:1303-1316` |
| A.2.5 cursor behavior on empty and active-voter rounds | `src/JBTokenDistributor.sol` `_claimPastRewardsForTokenId`, `_claimRewardsFor`; `src/JB721Distributor.sol` `_claimPastRewardsForToken` |
| A.2.6 burned tokens skipped in vesting | `src/JB721Distributor.sol:388` |
| A.3.1 permissionless `beginVesting` validation | `src/JBDistributor.sol` `_beginVesting`, `_validateTokenIds` |
| A.3.2 collection beneficiary guard | `src/JBDistributor.sol` `_requireCanCollectTo`, `_claimBeneficiaryOf` |
| A.3.3 721 strictly-increasing tokenIds | `src/JB721Distributor.sol:445-462` |
| A.4.1 active loan blocks collection | `src/JBDistributor.sol:414, 1256, 1386-1393` |
| A.4.2 one outstanding loan per position | `src/JBDistributor.sol:682-687` |
| A.4.3 pending-loan sentinel reentrancy lock | `src/JBDistributor.sol:709-718` |
| A.4.4 collateral = unclaimed vesting at borrow | `src/JBDistributor.sol:690-693` |
| A.4.5 vestingDataCount boundary at borrow | `src/JBDistributor.sol:696, 910-919` |
| A.4.6 repay restores exact collateral | `src/JBDistributor.sol:858-878` |
| A.4.7 native repay refund after loan settled (checks-effects-interactions) | `src/JBDistributor.sol` `repayVestingLoan` / `_repayLoanSource` |
| A.4.8 ERC-20 repay balance-delta check | `src/JBDistributor.sol:813-819` |
| A.4.9 approve/clear bracket | `src/JBDistributor.sol:822-834` |
| A.4.11 write-off needs liquidation | `src/JBDistributor.sol:643-646, 893-945` |
| A.4.12 revnet-token gate | `src/JBDistributor.sol:1101-1109` |
| A.4.13 VESTING_ROUNDS != 0 | `src/JBDistributor.sol:554` |
| A.4.14 BURN_TOKENS grant gated on revLoans != 0 | `src/JBDistributor.sol:237-248` |
| A.5.1 recycleExpiredRewards permissionless recycle | `src/JBDistributor.sol:304-327, 1060-1096` |
| A.5.2 CLAIM_DURATION==0 → no expiry | `src/JBDistributor.sol:1155-1173` |
| A.5.3 lazy claim handles expired rounds | `src/JBTokenDistributor.sol` `_claimRewardsFor`, `src/JB721Distributor.sol` `_claimPastRewardsForToken` |
| A.5.4 releaseForfeitedRewards requires burns | `src/JBDistributor.sol:341-365`, `src/JBTokenDistributor.sol:334-338`, `src/JB721Distributor.sol:468-474` |
| A.5.5 forfeit recycles into current round | `src/JBDistributor.sol:1224-1228` |
| C.2 `processSplitWith` terminal/controller gate (token) | `src/JBTokenDistributor.sol:107-145` |
| C.3 `processSplitWith` terminal/controller gate (721) | `src/JB721Distributor.sol:125-163` |
| D.4 `_requireNotAcceptingToken` reentrancy guard | `src/JBDistributor.sol:1377-1380` |
| D.5 per-hook reward-pool isolation | `src/JBDistributor.sol:148-199` |
| D.10 inventory conservation | `src/JBDistributor.sol:1007-1017, 704-706, 865-867, 925-928` |
| E.1 no global admin (constructor) | `src/JBDistributor.sol:218-249` |

For the protocol-wide third-party attack-surface reasoning that motivates these invariants, see [`../INVARIANTS.md`](../INVARIANTS.md) Section C.19.
