# Audit Instructions

## Scope

All Solidity source files in `src/`:

| File | Lines | Description |
|------|-------|-------------|
| `JBDistributor.sol` | ~350 | Abstract base: round logic, vesting, claiming, forfeiture |
| `JBTokenDistributor.sol` | ~100 | ERC20Votes staking + IJBSplitHook integration |
| `JB721Distributor.sol` | ~120 | JB 721 NFT staking + IJBSplitHook integration |
| `interfaces/` | ~80 | Public API definitions |
| `structs/` | ~15 | JBTokenSnapshotData, JBVestingData |

Total: ~665 lines of Solidity.

## Reading Order

1. `src/structs/` — data structures
2. `src/interfaces/IJBDistributor.sol` — public API
3. `src/JBDistributor.sol` — core logic (start here for bugs)
4. `src/JBTokenDistributor.sol` — ERC20Votes concrete
5. `src/JB721Distributor.sol` — 721 concrete

## System Model

```
Funding:
  Project Split → processSplitWith() → _balanceOf[hook][token] += amount
  Anyone        → fund()             → _balanceOf[hook][token] += amount

Distribution cycle (per round):
  beginVesting() → snapshot(balance - vestingAmount) → vest pro-rata to each tokenId
                   │
                   └─ vestingDataOf[hook][tokenId][token].push({releaseRound, amount, shareClaimed:0})

Claiming:
  collectVestedRewards() → linear unlock: (currentRound - claimRound) / vestingRounds
                         → transfer unlocked portion → update shareClaimed

Forfeiture (721 only):
  releaseForfeitedRewards() → return unvested portion of burned NFT to hook balance
```

## Critical Invariants

1. `sum(all vesting amounts) + sum(all balances) == sum(all funds received)` (conservation)
2. A tokenId can only have one active vesting entry per releaseRound (no double-vest)
3. `shareClaimed` is monotonically non-decreasing, bounded by `MAX_SHARE`
4. Burned tokens cannot collect rewards (721) / non-delegated tokens get nothing (ERC20)
5. `snapshotAtRoundOf` is write-once per hook/token/round

## Threat Model

- **Attacker goal**: Extract more rewards than their pro-rata stake entitles them to
- **Attack vectors**:
  - Flash-loan stake manipulation before `beginVesting()` (mitigated: uses past block via `getPastVotes`)
  - Double-claim across rounds (mitigated: releaseRound uniqueness check)
  - Reentrancy during `collectVestedRewards` (mitigated: state updated before transfer)
  - Grief `beginVesting` to lock out a round (mitigated: permissionless, idempotent per round)
  - Manipulate `_totalStake()` via 721 minting right before `beginVesting()` (live state risk — see RISKS.md)

## Hotspots

1. **`_vestTokenIds()`** — Pro-rata math, snapshot creation, double-vest prevention
2. **`_unlockTokenIds()`** — Linear vesting math, `shareClaimed` accounting
3. **`_totalStake()` in JB721Distributor** — Live tier iteration, burned NFT exclusion
4. **`processSplitWith()`** — Balance-delta for FOT safety, caller validation

## Finding Bar

- **Critical**: Fund loss, bypass of ownership checks, double-claim
- **High**: Permanent DoS of claiming, incorrect pro-rata distribution
- **Medium**: Dust accumulation beyond acceptable bounds, gas griefing
- **Low**: Informational, style, gas optimizations
