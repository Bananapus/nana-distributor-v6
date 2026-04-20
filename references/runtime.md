# Runtime

## Core role

`JBDistributor` tracks balances per `(hook, rewardToken)`, allocates a round's claimable amount when vesting begins, and releases rewards over fixed vesting rounds.

`JBTokenDistributor` uses `IVotes` checkpoints. Each `tokenId` encodes a staker address, and stake is `getPastVotes(encodedAddress, roundStartBlock(currentRound()))`.

`JB721Distributor` uses the 721 hook store. Stake is derived from each token's tier `votingUnits`, while total stake sums minted-minus-burned supply across all tiers.

## High-risk areas

### Round and checkpoint semantics

The token distributor depends on checkpointed voting power at the round start block. Holders must delegate for `getPastVotes` to count them, and undelegated supply can leave rewards stranded in the pool for later rounds.

### Funding path split

`processSplitWith` supports two funding patterns:

- Terminal path: pull tokens via allowance and credit the actual received amount.
- Controller path: assume tokens were transferred before the hook call and credit `context.amount`.

Mixing these assumptions causes under- or over-accounting.

### 721 burned-token behavior

The 721 distributor excludes burned NFTs from total stake and treats `ownerOf` failure as burn evidence. Changes to burn detection or tier accounting can change reward shares retroactively.

## Tests to trust first

| Test file | What it covers |
|---|---|
| [`test/JBTokenDistributor.t.sol`](../test/JBTokenDistributor.t.sol) | Checkpointed vote allocation, non-delegated supply behavior, vesting flow, split-hook funding |
| [`test/JB721Distributor.t.sol`](../test/JB721Distributor.t.sol) | Tier-based share math, burned token handling, split-hook funding, vesting collection |
| [`test/invariant/JB721DistributorInvariant.t.sol`](../test/invariant/JB721DistributorInvariant.t.sol) | Longer-lived 721 accounting relationships that are easier to break than unit tests suggest |
