# Bananapus Distributor V6

Token distribution and linear vesting system for Juicebox V6 projects.

| Contract | Description |
|----------|-------------|
| `JBDistributor` | Abstract base. Round-based distribution with linear vesting over N rounds. |
| `JBTokenDistributor` | For ERC20Votes stakers. Stake = delegated voting power at round start. Singleton. |
| `JB721Distributor` | For JB 721 NFT holders. Stake = tier's `votingUnits`. Burned NFTs excluded. Singleton. |

Both concrete distributors implement `IJBSplitHook` for direct integration with Juicebox payout splits.

## Mental Model

1. Project pays into distributor via payout split (or direct `fund()` call)
2. Anyone calls `beginVesting()` at round start — snapshots balances and begins linear vest
3. Stakers call `collectVestedRewards()` to claim their pro-rata share as it vests
4. Burned NFT rewards are reclaimable via `releaseForfeitedRewards()`

## Read First

1. `src/interfaces/IJBDistributor.sol` — full public API
2. `src/JBDistributor.sol` — core vesting logic
3. `src/JBTokenDistributor.sol` or `src/JB721Distributor.sol` — concrete implementations

## Install

```bash
npm install @bananapus/distributor-v6
```

## Develop

```bash
npm install
forge build
forge test
```

## Layout

```
src/
├── JBDistributor.sol           # Abstract base: rounds, vesting, claiming
├── JBTokenDistributor.sol      # ERC20Votes implementation + IJBSplitHook
├── JB721Distributor.sol        # JB 721 NFT implementation + IJBSplitHook
├── interfaces/
│   ├── IJBDistributor.sol
│   ├── IJBTokenDistributor.sol
│   └── IJB721Distributor.sol
└── structs/
    ├── JBTokenSnapshotData.sol # {balance, vestingAmount} per round
    └── JBVestingData.sol       # {releaseRound, amount, shareClaimed}
test/
├── unit/                       # Unit tests for each contract
└── invariant/                  # Stateful fuzz tests
```

## Risks

See [RISKS.md](./RISKS.md).
