# Administration

## At a Glance

| Property | Value |
|----------|-------|
| Admin role | None — fully permissionless |
| Upgradeability | None — immutable |
| Pause mechanism | None |
| Fee mechanism | None |
| Owner | None |

## Roles

This system is **fully permissionless**. There is no admin, owner, or governance role.

## Access Control

| Function | Who can call | Gate |
|----------|-------------|------|
| `fund()` | Anyone | — |
| `beginVesting()` | Anyone | — |
| `collectVestedRewards()` | Token owner (ERC-721) or staker (ERC-20) | `_canClaim()` ownership check |
| `releaseForfeitedRewards()` | Anyone (only for burned NFTs) | `_tokenBurned()` check |
| `processSplitWith()` | Project terminal or controller | `DIRECTORY` validation |

## Immutable Configuration

Set at deployment, never changeable:

- `startingBlock` — block when distributor was deployed
- `roundDuration` — blocks per round
- `vestingRounds` — number of rounds for full vesting

## Routine Operations

None required. The system operates autonomously once deployed.

- `beginVesting()` should be called once per round per hook/token pair (permissionless, incentive-compatible)
- `collectVestedRewards()` called by token holders at their convenience
- Rewards never expire — uncollected rewards remain claimable indefinitely

## Admin Boundaries

- No contract can be paused or upgraded
- No parameters can be changed post-deployment
- No funds can be extracted except through the defined claiming mechanisms
- No emergency withdrawal function exists
