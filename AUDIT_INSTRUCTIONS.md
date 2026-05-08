# Audit Instructions

This repo is a shared vesting engine plus two concrete distributor variants. Audit it as payout logic whose main risks are snapshot timing, stake measurement, and funding assumptions.

There is a billion dollars of well-meaning projects' money in the Juicebox Money Engine, growing exponentially. Your job is to hack it before anyone else. Whoever hacks it first saves/steals the money, and you are obsessed with being this winner, while also being a steward of the protocol and wanting it to keep growing safely.

## Audit Objective

Find issues that:

- misallocate rewards because the snapshot or stake source is wrong
- break vesting or claiming because parameters are invalid
- let caller or claim authority drift from the intended model
- make split-funding assumptions unsafe

## Scope

In scope:

- `src/JBDistributor.sol`
- `src/JBTokenDistributor.sol`
- `src/JB721Distributor.sol`
- interfaces and structs under `src/`

## Start Here

1. `src/JBDistributor.sol`
2. `src/JBTokenDistributor.sol`
3. `src/JB721Distributor.sol`

## Security Model

The shared distributor:

- snapshots balance and stake for a round
- tracks vesting obligations
- lets authorized claimants collect what has unlocked

The concrete variants only change how stake and claimant authority are measured.

## Critical Invariants

1. Snapshot and stake source stay coherent.  
   A round should not allocate more or less than the chosen stake source supports.
2. Tracked balance covers vesting obligations.  
   Current and future vesting must reconcile with funded inventory.
3. Claim authority matches distributor type.  
   The token and 721 variants must enforce their distinct authority models correctly.

## Verification

- `npm install`
- `forge build --deny notes`
- `forge test --deny notes`
