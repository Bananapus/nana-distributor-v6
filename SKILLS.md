# Juicebox Distributor

## Use This File For

- Use this file when the task touches reward distribution, split-hook funding, round-based vesting, IVotes checkpoints, or 721 staking rewards.
- Start here when the issue is about how distributor balances become claimable rewards, then decide whether the bug is in shared vesting math, funding-path classification, or stake-source accounting.

## Read This Next

| If you need... | Open this next |
|---|---|
| Core vesting and accounting flow shared by both variants | [`src/JBDistributor.sol`](./src/JBDistributor.sol) |
| ERC-20 or `IVotes` staking distribution | [`src/JBTokenDistributor.sol`](./src/JBTokenDistributor.sol), [`test/JBTokenDistributor.t.sol`](./test/JBTokenDistributor.t.sol) |
| 721 tier-based staking distribution | [`src/JB721Distributor.sol`](./src/JB721Distributor.sol), [`test/JB721Distributor.t.sol`](./test/JB721Distributor.t.sol) |
| Runtime and operational invariants | [`references/runtime.md`](./references/runtime.md), [`references/operations.md`](./references/operations.md) |
| Deployment inputs and operator assumptions | [`script/Deploy.s.sol`](./script/Deploy.s.sol), [`foundry.toml`](./foundry.toml) |

## Repo Map

| Area | Where to look |
|---|---|
| Shared distributor base | [`src/JBDistributor.sol`](./src/JBDistributor.sol) |
| IVotes distributor | [`src/JBTokenDistributor.sol`](./src/JBTokenDistributor.sol) |
| 721 distributor | [`src/JB721Distributor.sol`](./src/JB721Distributor.sol) |
| Tests | [`test/`](./test/) |

## Purpose

Split-hook distributor repo for Juicebox V6. It receives funds from payout splits, snapshots stake for either `IVotes` token holders or 721 tier holders, and releases rewards through round-based linear vesting.

## Reference Files

- Open [`references/runtime.md`](./references/runtime.md) when you need funding mechanics, vesting invariants, or the trust boundaries between terminals, controllers, and stake sources.
- Open [`references/operations.md`](./references/operations.md) when you need deployment inputs, change-specific validation guidance, or the most common stale-assumption traps in checkpointed reward accounting.

## Working Rules

- Start in [`src/JBDistributor.sol`](./src/JBDistributor.sol) for any accounting or vesting bug. The concrete distributor contracts mainly define stake ownership and funding authorization.
- Treat round boundaries, `getPastVotes` checkpoints, and burned-721 handling as high-risk. Small changes here can silently misallocate rewards.
- Vesting state, snapshot state, and token balance state must reconcile. If one changes, verify the other two explicitly.
- When debugging `processSplitWith`, separate terminal allowance pulls from controller pre-funding behavior before changing token accounting.
- For the token distributor, remember that undelegated supply lowers claimable rewards because `getPastTotalSupply` can exceed delegated votes.
