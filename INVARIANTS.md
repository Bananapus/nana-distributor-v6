# Invariants of `nana-distributor-v6`

Last updated: 2026-05-28.

Scope: the three production contracts in `src/` — the abstract base `JBDistributor` and its two concrete specializations `JBTokenDistributor` (IVotes ERC-20 staker) and `JB721Distributor` (Juicebox 721 NFT staker) — plus the pure helper library `src/libraries/JBVestingMath.sol`. A distributor accumulates reward tokens per-hook, snapshots the staker set once per round at a strictly-past block, allocates the snapshotted pot pro-rata by stake, and vests each staker's share linearly over `VESTING_ROUNDS` rounds. Reward tokens that are **revnet** project tokens (owned by the configured `REVOwner`) can additionally be used as collateral for a distributor-held `REVLoans` loan, deferring collection until repayment.

This file is the per-repo scoped invariants doc. The protocol-wide guarantees for the seven deployed revnets live in [`../INVARIANTS.md`](../INVARIANTS.md); section C.19 there summarizes this repo from the protocol's perspective.

---

# Section A — Guarantees to Stakers

## A.1 Snapshot fairness

- **A.1.1 Round snapshot is `block.number - 1`, locked on first interaction.** `_ensureSnapshotBlockFor` writes `roundSnapshotBlock[round] = block.number - 1` once per round and never overwrites it (`src/JBDistributor.sol:1255-1262`). The strictly-past block is required by both `IVotes.getPastVotes` and `IJB721Checkpoints.ownerOfAt`, and means the first interaction of the round cannot manipulate the eligible staker set.
- **A.1.2 Snapshot is eagerly armed for the next round.** Every snapshot-aware code path also locks `round + 1` via `_ensureSnapshotBlock` (`src/JBDistributor.sol:1244-1248`). This blocks a same-block "mint NFT → poke → claim" sequence from claiming pro-rata in the round in which the staker first existed.
- **A.1.3 `poke()` is permissionless.** Any keeper or frontend can call `poke()` to lock the current round's snapshot block before any pay/claim activity (`src/JBDistributor.sol:385-387`). Locking earlier is always equal or better for stakers; locking later cannot exceed the prevailing `block.number - 1`.
- **A.1.4 Per-round reward pots are snapshot-immutable.** When `_recordRewardRound` first credits a round, it writes `snapshotBlock`, `claimDeadline`, and `totalStake` into `rewardRoundOf[hook][token][round]` (`src/JBDistributor.sol:1135-1165`). Subsequent funding in the same round increases `.amount` but never re-snapshots stake or block — late mints cannot dilute earlier round contributors.
- **A.1.5 Token-distributor stake is delegated voting power at the snapshot block.** `JBTokenDistributor._tokenStake` and `_totalStake` route through `IVotes.getPastVotes` / `IVotes.getPastTotalSupply` at the round's snapshot block (`src/JBTokenDistributor.sol:395-407`). Holders who have not delegated (even to themselves) are not stakers; this is by design — IVotes participation is opt-in.
- **A.1.6 721 stake is `min(tier.votingUnits, owner.pastVotes)` at the snapshot block.** `JB721Distributor._tokenStake` queries the hook's checkpoints module: `_snapshotOwnerOf` returns the owner-at-snapshot (or zero), and `IVotes.getPastVotes` on the checkpoints module gates that owner's effective claim (`src/JB721Distributor.sol:599-621`). Late mints, post-snapshot transfers, and undelegated owners receive zero.
- **A.1.7 Per-owner voting-power cap across an NFT batch.** When an owner holds multiple NFTs in the batch, `_vestSingleToken` and `_claimRewardRoundForTokenId` use per-owner `consumed[]` accounting to cap the aggregate claim at the owner's snapshot `pastVotes`, persisted into `_consumedVotesOf[hook][token][round][owner]` across calls (`src/JB721Distributor.sol:397-401, 537-542, 681-794`). An owner with N NFTs of V voting units each cannot claim `N×V` if `pastVotes < N×V`.

## A.2 Allocation & vesting math

- **A.2.1 Pro-rata allocation by stake.** Each token ID's share is `mulDiv(distributable, tokenStake, totalStake)` (`src/JBDistributor.sol:1518-1520`, `src/JBTokenDistributor.sol:342-344`, `src/JB721Distributor.sol:469`).
- **A.2.2 Linear vesting via cumulative-share math.** `lockedShareOf` returns `(releaseRound - currentRound) * MAX_SHARE / VESTING_ROUNDS`; `newlyClaimableAmountOf` computes the unlock delta as the difference of two `mulDiv` rounds against the cumulative `shareClaimed`, not the incremental share, so floor-rounding dust cannot be stranded over partial collections (`src/libraries/JBVestingMath.sol:16-55`, `src/JBDistributor.sol:484-507, 1419-1449`). The final `unclaimedAmountOf` settles the last unlock as `amount - mulDiv(amount, shareClaimed, MAX_SHARE)` which releases dust at full vest (`src/libraries/JBVestingMath.sol:63-73`).
- **A.2.3 `MAX_SHARE = 100_000`.** The denominator constant for vesting share arithmetic (`src/JBDistributor.sol:109`).
- **A.2.4 Vesting-entry boundaries are append-only.** `vestingDataOf` is `push`-only during `_vestTokenIds` and `_claimPastRewardsForTokenId`; `latestVestedIndexOf` only ever advances forward over contiguously-exhausted entries (`src/JBDistributor.sol:1454-1465`).
- **A.2.5 Zero-distributable / zero-stake rounds do not consume the cursor.** `beginVesting` reverts `JBDistributor_NothingToDistribute` if `snapshot.balance - snapshot.vestingAmount == 0` (`src/JBDistributor.sol:315-320`). For lazy claim, the cursor is advanced past zero-stake or zero-amount rounds anyway so they are not rescanned forever (`src/JBTokenDistributor.sol:285`, `src/JB721Distributor.sol:336`).
- **A.2.6 Burned tokens are excluded.** `_vestTokenIds` and `_vestSingleToken` skip token IDs where `_tokenBurned == true` (`src/JBDistributor.sol:1498-1503`, `src/JB721Distributor.sol:695`), so a burned NFT can never overbook vesting against the snapshot-locked total stake (which excludes burned units).

## A.3 Collection authorization

- **A.3.1 `collectVestedRewards` is gated to the token owner.** `_requireCanClaimTokenIds` reverts unless every requested token ID's `_canClaim` returns true for `msg.sender` (`src/JBDistributor.sol:574-583`). For `JBTokenDistributor`, `_canClaim` requires `tokenId == uint256(uint160(msg.sender))` and reverts on high-bit aliasing (`src/JBTokenDistributor.sol:369-375`). For `JB721Distributor`, `_canClaim` requires `IERC721.ownerOf(tokenId) == msg.sender` (`src/JB721Distributor.sol:554-556`).
- **A.3.2 Non-owner cannot start vesting on token-distributor stakes.** `JBTokenDistributor.beginVesting` overrides the base to additionally require `_requireCanClaimTokenIds` (`src/JBTokenDistributor.sol:153-170`). This prevents a third party from starting a staker's vesting clock before the staker actually claims.
- **A.3.3 NFT batches must be strictly increasing.** `JB721Distributor._requireCanClaimTokenIds` reverts `JB721Distributor_TokenIdsNotIncreasing` if `tokenIds` is not strictly ascending, so the same NFT cannot appear twice in one call (`src/JB721Distributor.sol:561-578`).
- **A.3.4 Beneficiary is caller-supplied, but only the owner can authorize.** Owner can direct vested rewards to any address; no third party can re-route the owner's vest stream.

## A.4 Loan-against-vesting protections

- **A.4.1 Collection blocked while a loan is outstanding.** `_unlockTokenIds` reverts via `_requireNoActiveVestingLoan` if `activeVestingLoanIdOf[hook][tokenId][token] != 0` (`src/JBDistributor.sol:1403, 1609-1616`). `collectableFor` returns 0 under the same condition (`src/JBDistributor.sol:467-468`).
- **A.4.2 One vesting position, one outstanding loan.** `_borrowAgainstVesting` reverts `JBDistributor_VestingLoanOutstanding` if an active loan already exists for the `(hook, tokenId, token)` triple (`src/JBDistributor.sol:794-799`).
- **A.4.3 Same-position reentrancy lock.** Before the external `REV_LOANS.borrowFrom` call (which burns collateral and may trigger callbacks), the active loan ID is set to the sentinel `_PENDING_VESTING_LOAN_ID = type(uint256).max`; the real loan ID is written on return (`src/JBDistributor.sol:821-830`).
- **A.4.4 Loan collateral is exactly the unclaimed vesting amount at borrow time.** `collateralCount = _unclaimedVestingAmountOf({hook, tokenId, token})` after bringing the staker current via `_claimPastRewards` (`src/JBDistributor.sol:801-805`).
- **A.4.5 Borrow-time vesting boundary is recorded.** `vestingDataCount` snapshots the length of the staker's `vestingDataOf` array at borrow time, so liquidation write-off cannot consume vesting entries that accrued *after* the loan was opened (`src/JBDistributor.sol:808, 1021-1035`).
- **A.4.6 Repay restores the exact collateral count.** `_restoreVestingCollateral` reverts `JBDistributor_InsufficientRepaidCollateral` if the balance delta after `REV_LOANS.repayLoan` is less than the original collateral count (`src/JBDistributor.sol:965-974`); excess (from a same-token source fee) is refunded to the repayer (`src/JBDistributor.sol:985-989`).
- **A.4.7 Native repay refunds overpayment.** Native `repayLoan` refunds `msg.value - repayBorrowAmount` to `msg.sender` via a `call`; native send failures revert (`src/JBDistributor.sol:910-917`).
- **A.4.8 ERC-20 repay credits exactly the amount pulled.** `safeTransferFrom` + balance-delta check reverts `JBDistributor_UnexpectedRepayAmount` if a fee-on-transfer or rebasing token short-credits the repay (`src/JBDistributor.sol:926-931`).
- **A.4.9 Allowance is approved and cleared per repay call.** `forceApprove({REV_LOANS, repayBorrowAmount})` immediately before, and `forceApprove({REV_LOANS, 0})` immediately after, the external `repayLoan` (`src/JBDistributor.sol:933-946`). Tokens that require explicit approval reset (USDT-style) are safe.
- **A.4.10 Repay is permissionless.** Anyone can repay any distributor-held loan; the collateral is always restored to the original token ID's vesting schedule, not the repayer (`src/JBDistributor.sol:694-742`). A third-party repay strictly helps the staker.
- **A.4.11 Write-off requires actual revnet liquidation.** `writeOffLiquidatedVestingLoan` reverts `JBDistributor_VestingLoanNotLiquidated` unless `REV_LOANS.loanOf(loanId).createdAt == 0` (`src/JBDistributor.sol:756-758`). A live loan must be repaid, not written off.
- **A.4.12 Loans only against revnet reward tokens.** `_revnetIdOf` reverts `JBDistributor_NotRevnetRewardToken` unless the reward token is registered as a JB project token AND that project is owned by the configured `REV_OWNER` (`src/JBDistributor.sol:1212-1221`).
- **A.4.13 Loans require non-zero `VESTING_ROUNDS`.** Borrow reverts `JBDistributor_VestingLoansDisabled` when `VESTING_ROUNDS == 0` (`src/JBDistributor.sol:665-666`).
- **A.4.14 Constructor grants `REVLoans` only `BURN_TOKENS` permission, only when configured.** The constructor wildcards `BURN_TOKENS` for the trusted `revLoans` operator (`src/JBDistributor.sol:256-267`); no other permission is delegated. If `revLoans == address(0)`, no permission is granted and `borrowAgainstVesting` reverts `JBDistributor_RevnetLoansNotConfigured` (`src/JBDistributor.sol:668-669`).

## A.5 Expiry & recycling — dust prevention

- **A.5.1 `burnExpiredRewards` recycles unclaimed inventory of expired rounds into the current round.** Permissionless. Only acts on rounds whose `claimDeadline != 0` and `block.timestamp >= claimDeadline` (`src/JBDistributor.sol:358-381, 1172-1208, 1310-1320`). `claimedAmount` is set to `amount` BEFORE the new round write, so the round cannot double-recycle.
- **A.5.2 `CLAIM_DURATION == 0` makes rewards never expire.** `_claimDeadlineFor` returns 0 (`src/JBDistributor.sol:1302-1308`) and `_rewardRoundExpired` returns false unconditionally (`src/JBDistributor.sol:1313-1320`).
- **A.5.3 Expired rounds short-circuit during lazy claim.** `JBTokenDistributor._claimRewardsFor` and `JB721Distributor._claimPastRewardsForToken` route expired rounds through `_recycleExpiredRewardRound` instead of distributing them (`src/JBTokenDistributor.sol:331-334`, `src/JB721Distributor.sol:298-301`). A staker who lazy-claims after a round expires gets nothing for that round but is not double-charged.
- **A.5.4 `releaseForfeitedRewards` requires tokenIds actually burned.** Reverts `JBDistributor_NoAccess` unless every requested tokenId returns `_tokenBurned == true` (`src/JBDistributor.sol:395-419`). For `JBTokenDistributor` this always reverts because `_tokenBurned` is hardcoded `false` (`src/JBTokenDistributor.sol:382-386`); only the 721 distributor exposes this path (`src/JB721Distributor.sol:584-590`).
- **A.5.5 Forfeited inventory recycles into the current round, not to the caller.** `_unlockRewards` with `ownerClaim=false` calls `_recordRewardRound` for the unlocked amount instead of transferring; the inventory stays inside the distributor (`src/JBDistributor.sol:1369-1375`). The `beneficiary` argument is intentionally unused on the forfeit path.

---

# Section B — Operator Surface

The distributor has **no global admin and no per-hook operator role**. There is no Ownable, no upgrade hook, no protocol-fee setter, no pause switch. All mutating surface is either:

- staker-owner-gated (`collectVestedRewards`, `beginVesting` on the token distributor, `borrowAgainstVesting`),
- terminal/controller-gated (`processSplitWith`),
- permissionless settlement (`fund`, `poke`, `burnExpiredRewards`, `releaseForfeitedRewards`, `repayVestingLoan`, `writeOffLiquidatedVestingLoan`, base `beginVesting`).

The only authority granted at construction is a wildcard `BURN_TOKENS` permission to `REV_LOANS`, gated on `revLoans != address(0)` (A.4.14). The distributor itself never receives a project-scoped permission and never holds a project NFT.

---

# Section C — Per-Contract Operation Inventory

## C.1 `JBDistributor` (abstract base) — `src/JBDistributor.sol`

### Constructor (one-shot)

- **`constructor(controller, revLoans, revOwner, initialRoundDuration, initialVestingRounds, initialClaimDuration)`** — reverts `JBDistributor_InvalidRoundDuration` if `initialRoundDuration == 0`. Stamps `STARTING_TIMESTAMP = block.timestamp`. Grants `BURN_TOKENS` to `revLoans` only when `revLoans != address(0)` (`src/JBDistributor.sol:237-268`).

### Permissionless funding

- **`fund(hook, token, amount) payable`** — anyone. For native, `msg.value` overrides `amount`; for ERC-20, pulls via `safeTransferFrom` and credits the actual balance delta. Reentrancy-guarded by `_acceptingToken` (`src/JBDistributor.sol:348-350, 1097-1113`).
  - **Invariants:** `_balanceOf[hook][token]` and `_accountedBalanceOf[token]` increase by exactly the accepted delta; the current round's `rewardRoundOf` pot is sealed with snapshot + total-stake on first credit; reentrancy via the reward token cannot mutate any other accounting path while `_acceptingToken != address(0)`.

### Permissionless settlement

- **`beginVesting(hook, tokenIds, tokens)`** — base implementation: permissionless (overridden in concrete subclasses, see C.2 / C.3). Records `_ensureSnapshotBlock` for current and next round, then vests pro-rata for each tokenId across each reward token. Reverts `JBDistributor_EmptyTokenIds` if empty, `JBDistributor_NothingToDistribute` per token if distributable is zero. Silently returns when `totalStake == 0` so funds carry to the next round (`src/JBDistributor.sol:280-339`).
- **`burnExpiredRewards(hook, token, rounds[]) → amount`** — permissionless (`src/JBDistributor.sol:358-381`). See A.5.1.
- **`releaseForfeitedRewards(hook, tokenIds, tokens, beneficiary)`** — permissionless; requires burned tokenIds (`src/JBDistributor.sol:395-419`). See A.5.4.
- **`poke()`** — permissionless snapshot lock-in (`src/JBDistributor.sol:385-387`). See A.1.3.

### Staker-owner gated

- **`collectVestedRewards(hook, tokenIds, tokens, beneficiary)`** — only the staker (see A.3.1). Auto-vests the current round if there is distributable, then unlocks vested amounts and transfers to `beneficiary`. Reentrancy-guarded (`src/JBDistributor.sol:558-625`). Native send failures revert via `JBDistributor_NativeTransferFailed`.
- **`borrowAgainstVesting(hook, tokenIds, tokens, sourceToken, minBorrowAmount, prepaidFeePercent, beneficiary) → (loanId, collateralCount)`** — only the staker. Requires `tokenIds.length == tokens.length == 1`, `VESTING_ROUNDS != 0`, `REV_LOANS != address(0)`, and the reward token must be a REVOwner-owned revnet project token (`src/JBDistributor.sol:639-688, 785-840`). See A.4.

### Permissionless loan settlement

- **`repayVestingLoan(loanId, maxRepayBorrowAmount) payable → paidOffLoanId`** — anyone (A.4.10). Reverts `JBDistributor_NoVestingLoan` if the loan is not distributor-tracked (`src/JBDistributor.sol:694-742`).
- **`writeOffLiquidatedVestingLoan(loanId) → collateralCount`** — anyone, only after revnet liquidation (A.4.11) (`src/JBDistributor.sol:747-762, 1005-1057`).

### Hook-overridable internals

- **`_canClaim(hook, tokenId, account) view → bool`** — abstract; subclass-defined ownership check.
- **`_tokenBurned(hook, tokenId) view → bool`** — abstract; subclass-defined burn check.
- **`_tokenStake(hook, tokenId) view → uint256`** — abstract; subclass-defined stake weight.
- **`_totalStake(hook, blockNumber) view → uint256`** — abstract; subclass-defined total at block.
- **`_claimPastRewards(hook, tokenIds, tokens)`** — abstract; subclass-defined lazy past-round materialization.
- **`_requireCanClaimTokenIds(hook, tokenIds) view`** — abstract; subclass-defined batch authorization.
- **`_vestTokenIds(...)` virtual** — overridable per-token vesting loop; base implements simple pro-rata, 721 overrides for per-owner cap (A.1.7).

### Views

- **`balanceOf`, `claimedFor`, `collectableFor`, `snapshotAtRoundOf`, `vestingLoanOf`, `currentRound`, `roundStartTimestamp`** plus public storage mappings (`activeVestingLoanIdOf`, `latestVestedIndexOf`, `roundSnapshotBlock`, `rewardRoundOf`, `totalVestingAmountOf`, `totalLoanedVestingAmountOf`, `vestingDataOf`) and immutables (`CLAIM_DURATION`, `CONTROLLER`, `ROUND_DURATION`, `REV_LOANS`, `REV_OWNER`, `STARTING_TIMESTAMP`, `VESTING_ROUNDS`, `MAX_SHARE`).

## C.2 `JBTokenDistributor` — `src/JBTokenDistributor.sol`

Concrete distributor for IVotes ERC-20 stakers. `tokenId` is the staker address encoded as `uint256(uint160(staker))`; high bits revert (A.3.1).

### Terminal/controller-only

- **`processSplitWith(JBSplitHookContext) payable`** — only `DIRECTORY.isTerminalOf(projectId, msg.sender)` OR `DIRECTORY.controllerOf(projectId) == msg.sender` (`src/JBTokenDistributor.sol:107-145`).
  - **Invariants:** for native, `msg.value == context.amount` exactly (reverts `JBTokenDistributor_NativeAmountMismatch`); for ERC-20, `msg.value == 0` (reverts `JBTokenDistributor_TokenMismatch`) and pull via balance-delta accounting; `hook = context.split.beneficiary` is the IVotes token address.

### Staker-owner-gated

- **`beginVesting(hook, tokenIds, tokens)`** — only the encoded staker. Calls `_claimPastRewards`, which materializes all completed past rounds (`< currentRound()`) into one fresh vesting entry per token (`src/JBTokenDistributor.sol:153-170, 220-301`).
- **`collectVestedRewards(hook, tokenIds, tokens, beneficiary)`** — only the encoded staker; auto-claims past rounds before unlocking (`src/JBTokenDistributor.sol:177-198`).

### Internals

- `_claimRewardsFor` iterates `[firstRound, lastRound]`, applies expiry recycling, and accumulates `mulDiv(round.amount, pastVotes, round.totalStake)` per round (`src/JBTokenDistributor.sol:314-361`).
- `_tokenBurned` is hardcoded `false`; `releaseForfeitedRewards` therefore always reverts on this distributor (A.5.4).
- `_canClaim` rejects `tokenId >> 160 != 0` to defeat address-alias attacks (`src/JBTokenDistributor.sol:369-375`).

### Views

- `supportsInterface` advertises `IJBTokenDistributor`, `IJBSplitHook`, `IERC165` (`src/JBTokenDistributor.sol:207-210`).
- `nextClaimRoundOf[hook][tokenId][token]` is the cursor for lazy past-round claims.
- `DIRECTORY` immutable.

### Receive

- **`receive() external payable`** — accepts native ETH (e.g. from payout splits) (`src/JBTokenDistributor.sol:97`).

## C.3 `JB721Distributor` — `src/JB721Distributor.sol`

Concrete distributor for Juicebox 721 NFT stakers. `tokenId` is the NFT token ID; stake is `min(tier.votingUnits, owner.pastVotes)` at the snapshot block (A.1.6); the per-owner cap holds across an NFT batch (A.1.7).

### Terminal/controller-only

- **`processSplitWith(JBSplitHookContext) payable`** — same auth pattern as C.2 with `JB721Distributor_*` errors (`src/JB721Distributor.sol:125-163`).

### Staker-owner-gated (current NFT owner)

- **`beginVesting(hook, tokenIds, tokens)`** — only the current NFT owner; tokenIds must be strictly increasing (A.3.3). Lazy-claims all completed past rounds with per-owner vote caps (`src/JB721Distributor.sol:170-187, 237-402`).
- **`collectVestedRewards(hook, tokenIds, tokens, beneficiary)`** — only the current NFT owner; auto-claims past rounds then unlocks (`src/JB721Distributor.sol:194-215`).

### Internals

- `_snapshotOwnerOf` uses staticcall to `IJB721Checkpoints.ownerOfAt` so hooks without the checkpoint API fail closed (return zero), making late mints + post-snapshot transfers ineligible rather than reverting the whole batch (`src/JB721Distributor.sol:647-666`).
- `_consumedVotesOf[hook][token][round][owner]` persists the per-owner consumed cap across separate calls (`src/JB721Distributor.sol:79-81, 395-401, 537-542`).
- `_tokenBurned` is a try-catch wrapper around `ownerOf` (`src/JB721Distributor.sol:584-590`).
- `_vestTokenIds` overrides the base to apply the per-owner cap during current-round vesting (`src/JB721Distributor.sol:489-543`).

### Views

- `supportsInterface` advertises `IJB721Distributor`, `IJBSplitHook`, `IERC165` (`src/JB721Distributor.sol:224-227`).
- `nextClaimRoundOf[hook][tokenId][token]` cursor and `DIRECTORY` immutable.

### Receive

- **`receive() external payable`** — accepts native ETH (`src/JB721Distributor.sol:113`).

## C.4 `JBVestingMath` — `src/libraries/JBVestingMath.sol`

Pure helpers. No state, no auth. Three functions:

- `lockedShareOf(releaseRound, currentRound, vestingRounds, maxShare) → lockedShare` — linear unlock formula (`src/libraries/JBVestingMath.sol:16-27`).
- `newlyClaimableAmountOf(amount, shareClaimed, lockedShare, maxShare) → (claimAmount, newShareClaimed)` — cumulative-share delta with dust release at full unlock (`src/libraries/JBVestingMath.sol:36-55`).
- `unclaimedAmountOf(amount, shareClaimed, maxShare) → unclaimedAmount` — `amount - paid` so the final unlock releases floor-division dust (`src/libraries/JBVestingMath.sol:63-73`).

---

# Section D — Cross-Cutting Invariants

- **D.1 Snapshot once per round, pokeable.** `roundSnapshotBlock[round]` is set on first interaction with `block.number - 1` and never overwritten; the next round is eagerly armed alongside (A.1.1, A.1.2). The first interaction of a round cannot redefine the eligible staker set (`src/JBDistributor.sol:1244-1262`).
- **D.2 Per-round pot is locked at first credit.** `JBRewardRoundData.snapshotBlock`, `claimDeadline`, and `totalStake` are stamped on the first non-zero `_recordRewardRound` call for `(hook, token, round)` and never re-stamped, so late mints cannot dilute earlier round contributors (A.1.4) (`src/JBDistributor.sol:1148-1161`).
- **D.3 Active vesting loan blocks collection.** `_unlockTokenIds` reverts and `collectableFor` returns zero whenever `activeVestingLoanIdOf[hook][tokenId][token] != 0` (A.4.1).
- **D.4 `_requireNotAcceptingToken` reentrancy guard.** Every state-mutating external entrypoint (`fund`, `beginVesting`, `collectVestedRewards`, `burnExpiredRewards`, `releaseForfeitedRewards`, `borrowAgainstVesting`, `repayVestingLoan`, `writeOffLiquidatedVestingLoan`, `processSplitWith` via `_acceptErc20FundsFrom`) checks `_acceptingToken == address(0)` (`src/JBDistributor.sol:1597-1603`). A callback-capable reward token cannot mutate claim accounting mid-`balanceOf`/`transferFrom` measurement, and a single inbound transfer cannot net against an outbound transfer to strand funds.
- **D.5 Per-hook reward-pool isolation.** `_balanceOf[hook][token]` and all reward-round / vesting / snapshot data are keyed by `hook`; one hook's stakers can never claim another hook's pool (`src/JBDistributor.sol:196-219`).
- **D.6 Cumulative-share math prevents dust stranding.** `newlyClaimableAmountOf` uses the difference of two `mulDiv` rounds against cumulative shares; `unclaimedAmountOf` releases floor-division dust at full vest (A.2.2). Successive partial collections always sum to the original allocation.
- **D.7 Append-only cursors.** `latestVestedIndexOf` and `nextClaimRoundOf` are monotonically non-decreasing; once a round / vesting entry is exhausted it is never re-walked.
- **D.8 `releaseForfeitedRewards` requires burns.** A non-burned token cannot have its rewards recycled away from the owner (A.5.4).
- **D.9 Borrow → repay restores collateral exactly; liquidation forfeits only collateralized entries.** `vestingDataCount` snapshot at borrow time bounds the write-off range, so vesting that accrued after the loan opened is preserved through liquidation (A.4.5) (`src/JBDistributor.sol:808, 1018-1035`).
- **D.10 Conservation: `_accountedBalanceOf[token] == Σ hook _balanceOf[hook][token] + Σ hook (totalLoanedVestingAmountOf[hook][token] burned-into-loans)`.** All inventory mutations (`_fund`, `_unlockRewards` for owner-claim, `_borrowAgainstVesting`, `_restoreVestingCollateral`, `_writeOffLiquidatedVestingLoan`) update both sides in lockstep.
- **D.11 No global admin.** The constructor grants only `BURN_TOKENS` to `REV_LOANS` (A.4.14). No protocol fees, no pause, no ownership rotation, no upgrade hook.

---

# Section E — Centralization Caveats

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

# Section F — Key Code References

| Invariant | File:lines |
|---|---|
| A.1.1 snapshot is `block.number - 1`, latched once | `src/JBDistributor.sol:1255-1262` |
| A.1.2 next-round snapshot eagerly armed | `src/JBDistributor.sol:1244-1248` |
| A.1.3 `poke()` permissionless | `src/JBDistributor.sol:385-387` |
| A.1.4 per-round pot sealed on first credit | `src/JBDistributor.sol:1135-1165` |
| A.1.5 token-distributor IVotes lookup | `src/JBTokenDistributor.sol:395-407` |
| A.1.6 721 stake = min(votingUnits, pastVotes) at snapshot owner | `src/JB721Distributor.sol:599-621, 647-666` |
| A.1.7 per-owner vote cap across NFT batch | `src/JB721Distributor.sol:397-401, 537-542, 681-794` |
| A.2.1 pro-rata mulDiv | `src/JBDistributor.sol:1518-1520`, `src/JBTokenDistributor.sol:342-344`, `src/JB721Distributor.sol:469` |
| A.2.2 cumulative-share math (dust prevention) | `src/libraries/JBVestingMath.sol:36-73`, `src/JBDistributor.sol:484-507, 1419-1449` |
| A.2.4 append-only vesting cursor | `src/JBDistributor.sol:1454-1465` |
| A.2.5 zero-distributable revert; cursor advance on empty rounds | `src/JBDistributor.sol:315-320`, `src/JBTokenDistributor.sol:285`, `src/JB721Distributor.sol:336` |
| A.2.6 burned tokens skipped in vesting | `src/JBDistributor.sol:1498-1503`, `src/JB721Distributor.sol:695` |
| A.3.1 `_canClaim` gating | `src/JBDistributor.sol:574-583`, `src/JBTokenDistributor.sol:369-375`, `src/JB721Distributor.sol:554-556` |
| A.3.2 token-distributor `beginVesting` owner-gated | `src/JBTokenDistributor.sol:153-170` |
| A.3.3 721 strictly-increasing tokenIds | `src/JB721Distributor.sol:561-578` |
| A.4.1 active loan blocks collection | `src/JBDistributor.sol:467-468, 1403, 1609-1616` |
| A.4.2 one outstanding loan per position | `src/JBDistributor.sol:794-799` |
| A.4.3 pending-loan sentinel reentrancy lock | `src/JBDistributor.sol:821-830` |
| A.4.4 collateral = unclaimed vesting at borrow | `src/JBDistributor.sol:801-805` |
| A.4.5 vestingDataCount boundary at borrow | `src/JBDistributor.sol:808, 1021-1035` |
| A.4.6 repay restores exact collateral | `src/JBDistributor.sol:965-989` |
| A.4.7 native repay refund | `src/JBDistributor.sol:910-917` |
| A.4.8 ERC-20 repay balance-delta check | `src/JBDistributor.sol:926-931` |
| A.4.9 approve/clear bracket | `src/JBDistributor.sol:933-946` |
| A.4.11 write-off needs liquidation | `src/JBDistributor.sol:756-758, 1005-1057` |
| A.4.12 revnet-token gate | `src/JBDistributor.sol:1212-1221` |
| A.4.13 VESTING_ROUNDS != 0 | `src/JBDistributor.sol:665-666` |
| A.4.14 BURN_TOKENS grant gated on revLoans != 0 | `src/JBDistributor.sol:256-267` |
| A.5.1 burnExpiredRewards permissionless recycle | `src/JBDistributor.sol:358-381, 1172-1208` |
| A.5.2 CLAIM_DURATION==0 → no expiry | `src/JBDistributor.sol:1302-1320` |
| A.5.3 lazy claim short-circuits expired rounds | `src/JBTokenDistributor.sol:331-334`, `src/JB721Distributor.sol:298-301` |
| A.5.4 releaseForfeitedRewards requires burns | `src/JBDistributor.sol:395-419`, `src/JBTokenDistributor.sol:382-386`, `src/JB721Distributor.sol:584-590` |
| A.5.5 forfeit recycles into current round | `src/JBDistributor.sol:1369-1375` |
| C.2 `processSplitWith` terminal/controller gate (token) | `src/JBTokenDistributor.sol:107-145` |
| C.3 `processSplitWith` terminal/controller gate (721) | `src/JB721Distributor.sol:125-163` |
| D.4 `_requireNotAcceptingToken` reentrancy guard | `src/JBDistributor.sol:1597-1603` |
| D.5 per-hook reward-pool isolation | `src/JBDistributor.sol:196-219` |
| D.10 inventory conservation | `src/JBDistributor.sol:1097-1129, 815-818, 977-979, 1037-1041` |
| E.1 no global admin (constructor) | `src/JBDistributor.sol:237-268` |

For the protocol-wide third-party attack-surface reasoning that motivates these invariants, see [`../INVARIANTS.md`](../INVARIANTS.md) Section C.19.
