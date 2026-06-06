# Runtime

## Core role

`JBDistributor` tracks balances per `(hook, rewardToken)`, allocates a round's claimable amount when vesting begins, and releases rewards over fixed vesting rounds.

`JBTokenDistributor` uses `IVotes` checkpoints. Each `tokenId` encodes a staker address, and stake is `getPastVotes(encodedAddress, roundStartBlock(currentRound()))`.

`JB721Distributor` uses the 721 hook store. Stake is derived from each token's tier `votingUnits`, while total stake sums minted-minus-burned supply across all tiers.

## High-risk areas

### Round and checkpoint semantics

The token distributor depends on checkpointed voting power at the reward round's snapshot block. Holders must delegate for `getPastVotes` to count them. Deployments with `CLAIM_DURATION == 0` use `getPastTotalSupply`, so undelegated supply can dilute claims; deployments with nonzero claim duration use `IJBActiveVotes.getPastTotalActiveVotes`, so undelegated balances such as AMM custody with no delegate do not share the pot.

### Funding path

`processSplitWith` uses a single funding pattern: the caller grants an ERC-20 allowance and `processSplitWith` pulls tokens via `transferFrom`, crediting the actual received amount.

### 721 burned-token behavior

The 721 distributor excludes burned NFTs from total stake and treats `ownerOf` failure as burn evidence. Changes to burn detection or tier accounting can change reward shares retroactively.

## Tests to trust first

| Test file | What it covers |
|---|---|
| [`test/JBTokenDistributor.t.sol`](../test/JBTokenDistributor.t.sol) | Checkpointed vote allocation, non-delegated supply behavior, vesting flow, split-hook funding |
| [`test/JB721Distributor.t.sol`](../test/JB721Distributor.t.sol) | Tier-based share math, burned token handling, split-hook funding, vesting collection |
| [`test/invariant/JB721DistributorInvariant.t.sol`](../test/invariant/JB721DistributorInvariant.t.sol) | Longer-lived 721 accounting relationships that are easier to break than unit tests suggest |
