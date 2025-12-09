# PRT: Predict, Resolve & Tally (Decentralized)

A bash tool to make predictions, resolve them, and tally your calibration.
Each prediction is hashed and committed to Solana blockchain for verifiable timestamps.

Fork of [NunoSempere/predict-resolve-tally](https://github.com/NunoSempere/predict-resolve-tally)

## Features

- **predict** - Make a new prediction (saved locally + hash sent to Solana)
- **resolve** - Resolve predictions whose dates have passed
- **tally** - See your calibration stats
- **verify** - Verify a single prediction against Solana
- **verifyall** - Verify all predictions against Solana

## Example of use

```
$ predict
> Statement: Before 1 July 2025 will SpaceX launch Starship to orbit?
> Probability (%): 70
> Date of resolution (year/month/day): 2025/07/01
Sending to Solana...
Hash: 360d8eb5257bbd40e997f58e6f929bd8a997eef5bbccdbee603b157e3b97f1d0
Tx: 4RFobBkCwbSHxs99taXf7CRFEFAZa8fFqhEUURzBS7rf...
View: https://explorer.solana.com/tx/4RFobBkCwbSHxs99...?cluster=devnet

$ verifyall
Verifying all predictions...

[OK] Before 1 July 2025 will SpaceX launch Starship to orbit?
     Committed: 2025-12-09 17:18:52 UTC

$ resolve
Before 1 July 2025 will SpaceX launch Starship to orbit? (2025/07/01)
> (TRUE/FALSE) TRUE

$ tally
0 to 10 : 0 TRUE and 0 FALSE
...
60 to 70 : 1 TRUE and 0 FALSE
...
```

## Installation

### 1. Dependencies

- bash
- openssl
- python3 with base58 (`pip install base58`)
- Solana CLI (https://docs.solana.com/cli/install-solana-cli-tools)

### 2. Configure .env

Copy `.env.example` to `.env` and fill in:

```
PREDICTIONS_DIR=~/path/to/your/predictions/folder
SOLANA_PRIVATE_KEY=your_base58_private_key_here
SOLANA_RPC=https://api.devnet.solana.com
```

For mainnet, use: `SOLANA_RPC=https://api.mainnet-beta.solana.com`

### 3. Create predictions directory

```
mkdir -p ~/path/to/your/predictions/folder
```

### 4. Add to .bashrc

```
[ -f /path/to/PRT.bash ] && source /path/to/PRT.bash
```

## How it works

1. When you `predict`, a random salt is generated
2. Hash = SHA256(statement|probability|date|salt)
3. Hash is sent to Solana as a memo transaction
4. Local file stores: hash, salt, tx_signature, prediction data
5. `verify` recalculates hash and compares with on-chain memo

This proves you made the prediction before the resolution date, without revealing it until you choose to.

## Gotchas

**TSV format**
- Data is stored as tab-separated values
- Don't use tabs in your statements

**Dates**
- Use year/month/day format (e.g., 2025/07/01)
- Always use two digits for month and day (07 not 7)

**Solana costs**
- Each prediction costs ~0.000005 SOL (~$0.001)
- Verification is free (read-only)

## Files

- `pendingPredictions.txt` - Predictions not yet resolved
- `resolvedPredictions.txt` - Resolved predictions with TRUE/FALSE
- `hashes.txt` - Hash, salt, tx_signature, and prediction data
