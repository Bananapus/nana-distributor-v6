# Administration

## At A Glance

| Item | Details |
| --- | --- |
| Scope | Round-based vesting and distribution configuration |
| Control posture | Mostly parameter- and caller-driven, with asset-specific authority checks |
| Highest-risk actions | Bad deployment parameters, wrong funding assumptions, and stale snapshot timing |
| Recovery posture | Some value can remain for future rounds, but bad parameters can brick an instance |

## Purpose

`nana-distributor-v6` has less admin complexity than many sibling repos, but deployment parameters and funding assumptions still create real control risk.

## Control Model

- vesting is mostly driven by deployment parameters and permissionless round starts
- claim authority differs by distributor type
- 721 forfeiture handling adds a separate recovery path not present in the token distributor

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Round starter | Any caller | Per distributor | Vesting is permissionless |
| Token claimant | Encoded claimant address | Per token slot | Token distributor authority model |
| NFT claimant | Current NFT owner | Per token ID | 721 distributor authority model |

## Privileged Surfaces

- deployment parameters
- funding flows
- claim entrypoints with distributor-specific authority checks
- 721 forfeiture release path

## Immutable And One-Way

- bad constructor parameters can permanently make an instance unusable
- snapshots define a round once taken
- vested or collected value does not rewind

## Operational Notes

- review round timing and vesting-round count before deployment
- verify the distributor holds the correct asset before starting rounds
- do not assume token and 721 variants behave identically

## Recovery

- unclaimed value can remain for future rounds
- 721 forfeiture release can recycle some value
- bad deployment parameters usually require a new distributor instance

## Admin Boundaries

- this repo does not create upstream entitlement logic
- permissionless vesting means operators do not fully control snapshot timing
- the distributor cannot make a missing or wrong stake source correct

## Source Map

- `src/JBDistributor.sol`
- `src/JBTokenDistributor.sol`
- `src/JB721Distributor.sol`
