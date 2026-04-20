# Audit Instructions

This repo distributes rewards over time to ERC-20 voting power or tiered 721 holders. Audit it as a vesting and pro-rata accounting system that is usually funded by split hooks.

## Audit Objective

Find issues that:
- let a claimant extract more than their pro-rata share
- break conservation between funded balances, vested balances, and claimed balances
- let a burned NFT or ineligible voting position continue claiming rewards
- double-vest or double-claim the same round
- trap rewards permanently through edge-case state transitions

## Scope

In scope:
- `src/JBDistributor.sol`
- `src/JBTokenDistributor.sol`
- `src/JB721Distributor.sol`
- all interfaces in `src/interfaces/`
- all structs in `src/structs/`
- `script/Deploy.s.sol`

## Start Here

1. `src/JBDistributor.sol`
2. `src/JBTokenDistributor.sol`
3. `src/JB721Distributor.sol`

## Security Model

The shared base contract receives funds, snapshots stake for a round, vests balances over time, and lets holders claim unlocked rewards.
- `JBTokenDistributor` derives stake from ERC-20 voting snapshots
- `JB721Distributor` derives stake from eligible 721 holdings and has forfeiture logic for burned NFTs
- anyone may fund, but vesting state should only release value once per round and claimant

## Roles And Privileges

| Role | Powers | How constrained |
|------|--------|-----------------|
| Funder | Add rewards to the distributor | Must not be able to corrupt claim accounting |
| Claimant | Collect unlocked rewards | Must remain bounded by snapshot stake and vesting progress |
| Split hook caller | Route project funds into the distributor | Must preserve actual received balances |

## Integration Assumptions

| Dependency | Assumption | What breaks if wrong |
|------------|------------|----------------------|
| ERC-20 voting checkpoints | Historical voting power reflects intended stake | Round allocations can be manipulated |
| 721 eligibility source | Ownership and burn status are authentic | Forfeiture and claim eligibility break |

## Critical Invariants

1. Funded balance equals live balance plus total unclaimed vested balance.
2. A token or holder cannot receive more than its round share.
3. A round is snapshotted at most once per token and funding asset.
4. `shareClaimed` is monotonic and cannot exceed the full vested amount.
5. Burned or otherwise ineligible positions cannot continue collecting rewards they no longer back.

## Attack Surfaces

- round-start vesting logic and snapshot timing
- linear unlock math during claims
- 721 forfeiture and burned-token handling
- split-hook funding paths and fee-on-transfer token deltas
- stake calculation right before a round begins

## Verification

- `npm install`
- `forge build`
- `forge test`
