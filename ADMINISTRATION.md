# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Permissionless distributor funding and vesting with terminal/controller-gated split-hook entry |
| Control posture | Nearly adminless with caller validation on a few paths |
| Highest-risk actions | Deploying with the wrong round duration or using the wrong distributor variant for the product |
| Recovery posture | Most mistakes require redeployment; there is no admin rescue or pause path |

## Purpose

`nana-distributor-v6` is almost entirely permissionless. The only hard gate is that payout-split funding through `processSplitWith(...)` must come from a recognized terminal or controller for the project. There is no owner, pause, or upgrade role.

## Control Model

- No owner
- No governance
- No pause
- No upgrade
- Terminal or controller validation for split-hook funding
- Holder-based claim checks for collection

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Anyone | No assignment | Global | Can fund and begin vesting |
| Reward claimant | Token ownership or encoded claimant model | Per position | Must satisfy `_canClaim(...)` |
| Terminal or controller | `JBDirectory` routing | Per project | Only these callers can use `processSplitWith(...)` |

## Privileged Surfaces

There are no owner-only or governance-only functions.

Access-controlled behavior is limited to:

- `processSplitWith(...)`: only a recognized terminal or controller for the project
- `collectVestedRewards(...)`: caller must satisfy `_canClaim(...)`
- `releaseForfeitedRewards(...)`: only works for token IDs that satisfy `_tokenBurned(...)`

Everything else that matters operationally, including `fund(...)` and `beginVesting(...)`, is permissionless.

## Immutable And One-Way

- `startingBlock`, `roundDuration`, and `vestingRounds` are constructor immutables.
- Vesting entries are append-only claim state for each hook, tokenId, and reward token.
- There is no admin rewrite or delete path for snapshot and vesting state.

## Operational Notes

- Call `beginVesting(...)` once per round and reward token set you actually intend to vest.
- Validate the chain-specific `roundDuration` before deployment; it is a real operational parameter, not metadata.
- Remember the two distributor variants use different stake models: current 721 state versus checkpointed `IVotes` state.

## Machine Notes

- Do not search for owner or governance roles here; they do not exist.
- Treat `processSplitWith(...)` caller validation and claimant checks as the only meaningful control logic.
- If product requirements need pausing, mutable schedules, or operator overrides, this repo is the wrong primitive.

## Recovery

- There is no admin rescue surface.
- If deployment parameters are wrong, the fix is a new distributor deployment.
- If a stake model is wrong for the product, use the correct distributor variant rather than expecting mutable reconfiguration.

## Admin Boundaries

- Nobody can pause distributions or claims.
- Nobody can change round duration or vesting length after deployment.
- Nobody can extract rewards except through the defined claim or forfeiture flows.
- Nobody can bypass terminal/controller validation on the split-hook funding path.

## Source Map

- `src/JBDistributor.sol`
- `src/JB721Distributor.sol`
- `src/JBTokenDistributor.sol`
- `test/JB721Distributor.t.sol`
