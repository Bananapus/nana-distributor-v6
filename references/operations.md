# Operations

## Change checklist

| If you're editing... | Verify... |
|---|---|
| `JBDistributor` vesting math | Claim totals, `totalVestingAmountOf`, and pool balances still reconcile across rounds |
| `JBTokenDistributor` checkpoint logic | `getPastVotes` and `getPastTotalSupply` are read at the intended round-start block |
| `JB721Distributor` stake math | Minted, remaining, and burned supply still produce the intended tier-weighted total stake |
| `processSplitWith` | Terminal allowance flow and controller pre-funding flow both preserve actual received balances |
| Deployment inputs | `DIRECTORY_ADDRESS`, `ROUND_DURATION`, and `VESTING_ROUNDS` match the intended chain and operator plan |

## Common failure modes

| Symptom | Likely cause |
|---|---|
| A holder gets no rewards in the token distributor | They never delegated, so `getPastVotes` returned zero |
| Rewards appear stuck in the distributor | Supply was undelegated, vesting never began for the target token IDs, or the round boundary assumption is wrong |
| 721 reward shares look diluted | Burned supply was not excluded correctly or token-to-tier mapping is wrong |
| Split-hook funding credits the wrong amount | The caller path was misclassified between allowance-pull and pre-funded controller flow |

## Read Next

- [`script/Deploy.s.sol`](../script/Deploy.s.sol) when the failure might be deployment config rather than distributor math.
- [`test/invariant/JB721DistributorInvariant.t.sol`](../test/invariant/JB721DistributorInvariant.t.sol) when a local patch looks safe but may have broken a longer-lived accounting invariant.
