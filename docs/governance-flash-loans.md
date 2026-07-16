# Governance Flash Loans Script

The `scripts/governance-flash-loans.ts` script enables flash loans on the Hydration Aave deployment via substrate governance.

## Purpose

Flash loans are disabled by default on new Aave reserves. This script constructs and submits a substrate governance proposal that calls `PoolConfigurator.setReserveFlashLoaning(asset, true)` for each target reserve via the `dispatcher.dispatchAsAaveManager` extrinsic.

## Usage

**Preview the governance call** (no on-chain submission):

```bash
HYDRA_NETWORK=lark npx ts-node scripts/governance-flash-loans.ts
```

**Execute the full governance flow** (note preimage, submit referendum, vote):

```bash
HYDRA_NETWORK=lark npx ts-node scripts/governance-flash-loans.ts --full-flow
```

**Optionally fund an EVM account** (mints WETH and whitelists for contract deployment):

```bash
HYDRA_NETWORK=lark EVM_ADDRESS=0x... npx ts-node scripts/governance-flash-loans.ts --full-flow --fund-evm
```

## Supported Networks

| Network     | WebSocket URL                        | Description          |
|-------------|--------------------------------------|----------------------|
| `zombie`    | `ws://localhost:8000`                | Local zombienet      |
| `lark`      | `wss://node.lark.hydration.cloud`    | Lark testnet         |
| `nice`      | `wss://rpc.nice.hydration.cloud`     | Nice testnet         |
| `hydration` | `wss://rpc.hydradx.cloud`            | Hydration mainnet    |

## Environment Variables

| Variable         | Required | Description                                      |
|------------------|----------|--------------------------------------------------|
| `HYDRA_NETWORK`  | No       | Target network (default: `lark`)                 |
| `EVM_ADDRESS`    | Only with `--fund-evm` | EVM address to fund and whitelist  |
| `FUND_AMOUNT`    | No       | Amount of WETH to mint (default: 10 WETH in wei) |

## What the Script Does

1. **Build governance calls** — For each asset (DOT, USDT, WETH, USDC), constructs an `evm.call` to `PoolConfigurator.setReserveFlashLoaning`, wrapped in `dispatcher.dispatchAsAaveManager`. All calls are batched with `utility.batchAll`.

2. **Preview mode** (default) — Prints the call structure, hex-encoded preimage, and hash. Does not submit anything on-chain.

3. **Full flow** (`--full-flow`) — Uses the `//Alice` development account to:
   - **Note the preimage** via `preimage.notePreimage`
   - **Submit a referendum** with Root origin via `referenda.submit`
   - **Place a decision deposit** via `referenda.placeDecisionDeposit`
   - **Vote AYE** with 50% of free balance via `convictionVoting.vote`
   - **Advance blocks** (dev nodes only) via `dev_newBlock` to finalize

On non-dev networks, the referendum will pass after the standard voting period ends.
