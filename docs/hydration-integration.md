# Hydration Integration

This document describes how the Aave ParaSwap adapter stack is integrated with [Hydration](https://hydration.net/), a substrate-based chain with an EVM-compatible runtime.

## Architecture Overview

On Ethereum mainnet the adapters route swaps through ParaSwap's Augustus contract. On Hydration there is no ParaSwap deployment — instead, swaps are routed through the substrate **route executor** pallet via a Dispatch precompile.

```
┌──────────────┐      ┌──────────────────┐      ┌──────────────────────┐
│ Aave Adapter │─────▶│  HydraAugustus   │─────▶│ Dispatch Precompile  │
│ (debt swap,  │      │ (sell / buy)     │      │     (0x0401)         │
│  repay, …)   │      │ patches amounts, │      │ route_executor.sell  │
│              │      │ transfers tokens │      │ route_executor.buy   │
└──────────────┘      └──────────────────┘      └──────────────────────┘
```

**HydraAugustus** implements the `IParaSwapAugustus` interface so the existing adapter contracts can call it without modification. Internally it:

1. Pulls tokens from the caller via `transferFrom`.
2. Approves the Dispatch precompile to spend the input token.
3. Patches the SCALE-encoded call data with runtime amounts.
4. Forwards the call to the Dispatch precompile.
5. Verifies output and sends received tokens back to the caller.

**HydraAugustusRegistry** implements `IParaSwapAugustusRegistry` and tracks which HydraAugustus addresses are valid. It is a simple owner-managed mapping.

## Dispatch Precompile (0x0401)

Hydration exposes substrate pallets to EVM contracts via precompiles. The Dispatch precompile at address `0x0401` accepts raw SCALE-encoded extrinsic data and executes it in the substrate runtime.

HydraAugustus calls `DISPATCH.call(data)` where `data` is the SCALE encoding of either `route_executor.sell(...)` or `route_executor.buy(...)`.

## SCALE Encoding Layout

The dispatch data follows this byte layout:

```
Offset    Size     Field
──────    ────     ─────
[0..2)    2 bytes  Pallet index + call index
[2..10)   8 bytes  Asset identifiers (asset_in / asset_out)
[10..26)  16 bytes First u128 amount (little-endian)
                   • sell: amount_in
                   • buy:  amount_out
[26..42)  16 bytes Second u128 amount (little-endian)
                   • sell: min_amount_out
                   • buy:  max_amount_in
[42..)    variable Route data (pool hops, asset IDs, etc.)
```

## `_patchAmounts()` — Runtime Amount Patching

The Aave adapters may overwrite ABI-level amounts at runtime. For example, "swap all balance" reads the actual debt/collateral balance on-chain, which differs from the frontend's original estimate baked into the SCALE payload.

`_patchAmounts(dispatchData, firstAmount, secondAmount)` overwrites the two u128 fields at offsets `[10..26)` and `[26..42)` with the correct values in little-endian byte order using inline assembly. This ensures the substrate runtime receives accurate amounts.

## Supported Pool Types

The Hydration route executor supports multiple DEX pool types:

- **Omnipool** — Hydration's single-sided AMM
- **XYK** — Traditional constant-product pools
- **Stableswap** — Curve-style pools for pegged assets
- **LBP** — Liquidity Bootstrapping Pools

Routes can chain multiple pools in a single swap.

## Key Differences from Mainnet ParaSwap

### `isContract` Workaround

On Hydration, ERC-20 tokens are substrate precompiles — they are callable addresses with no EVM bytecode. OpenZeppelin's `SafeERC20` uses `Address.isContract()` which checks `extcodesize > 0` and would incorrectly reject these tokens. All token interactions in HydraAugustus (and the modified base adapters) use low-level `call` instead.

### u128 Amount Cap

Substrate balances are `u128`. All amounts passed to HydraAugustus are validated to be `<= type(uint128).max` before being SCALE-encoded. The adapters use `type(uint128).max` (instead of `type(uint256).max`) for approval amounts.

### Constructor Refactor

The base adapter constructors accept the Aave Pool address directly as a parameter (instead of deriving it from the PoolAddressesProvider) because the Hydration pool address must be known at deploy time.

## Deployment Steps

1. **Deploy HydraAugustusRegistry**
   ```
   constructor(address initialAugustus)
   ```
   Pass `address(0)` if deploying Augustus separately, or the Augustus address to register it immediately.

2. **Deploy HydraAugustus**
   ```
   constructor(address dispatch)
   ```
   Pass the Dispatch precompile address (typically `0x0401`).

3. **Register Augustus** (if not done in step 1)
   ```
   registry.setAugustus(augustusAddress, true)
   ```

4. **Deploy Adapters** (DebtSwap, LiquiditySwap, Repay)
   Pass the PoolAddressesProvider, Pool address, and AugustusRegistry to each adapter constructor.

5. **Call `approvePoolReserves()`** on each adapter
   This is a required post-deployment step. It pre-approves all current pool reserves so the adapters can supply/repay on behalf of users.

6. **Enable flash loans** (if needed)
   Use the governance script to enable flash loans on the target reserves:
   ```
   HYDRA_NETWORK=lark npx ts-node scripts/governance-flash-loans.ts --full-flow
   ```
   See [governance-flash-loans.md](./governance-flash-loans.md) for details.
