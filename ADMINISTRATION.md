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

- vesting is driven by deployment parameters, round timing, and claimant-initiated materialization
- claim authority differs by distributor type
- 721 forfeiture handling adds a separate recovery path not present in the token distributor

## Roles

| Role | How Assigned | Scope | Notes |
| --- | --- | --- | --- |
| Snapshot keeper | Any caller | Per distributor | `poke` can lock snapshot blocks before funding or claims |
| Expiry keeper | Any caller | Per expired reward round | `burnExpiredRewards` clears unclaimed inventory after the distributor's deadline |
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
- choose claim duration carefully at deployment; `0` keeps all funding paths non-expiring
- verify the distributor holds the correct asset before claimants start vesting
- do not assume token and 721 variants behave identically

## Recovery

- unclaimed reward rounds remain reserved for historical stakers or NFT owners; they do not become someone else's
  reward merely because the claimant is late
- expiring reward rounds are the exception: after the configured deadline, anyone can burn the unclaimed remainder
- 721 forfeiture release can recycle some value
- bad deployment parameters usually require a new distributor instance

## Admin Boundaries

- this repo does not create upstream entitlement logic
- token and 721 vesting are claimant-initiated; operators still need to manage snapshot timing with `poke` where
  predictable snapshots matter
- the distributor cannot make a missing or wrong stake source correct

## Source Map

- `src/JBDistributor.sol`
- `src/JBTokenDistributor.sol`
- `src/JB721Distributor.sol`
