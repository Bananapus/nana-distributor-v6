# Changelog

## 0.0.1

Initial release of the Juicebox V6 distributor system.

### Features

- **JBDistributor**: Abstract base contract with round-based distribution and configurable linear vesting.
- **JBTokenDistributor**: Singleton distributor for IVotes-compatible ERC-20 tokens. Stake weight = delegated voting power at round start.
- **JB721Distributor**: Singleton distributor for JB 721 NFT holders. Stake weight = tier's `votingUnits`. Burned NFTs excluded from stake; forfeited rewards reclaimable.
- Both implement `IJBSplitHook` for direct integration with Juicebox payout splits.
- Linear vesting over configurable number of rounds.
- Fee-on-transfer token support via balance-delta pattern.
- Native ETH distribution support.
