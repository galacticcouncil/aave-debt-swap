// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

/**
 * @title HydraRouteEncoder
 * @notice SCALE-encodes Hydration `pallet_route_executor` calls (`sell` / `buy`) with an
 *         EMPTY route, for dispatch through the Frontier dispatch precompile (0x0401).
 * @dev We intentionally emit an empty route (SCALE `compact(0)` = the single byte `0x00`).
 *      The router then resolves the pools from its own governance-set on-chain storage
 *      (`Routes`), falling back to a default pool if none is set — verified in
 *      hydration-node/pallets/route-executor/src/lib.rs `get_route_or_default` (:561):
 *      `if !route.is_empty() { route } else { on-chain route }`. Governance sets the real
 *      PRIME⇄HOLLAR route once on the router via `set_route` (:316) — never in this contract.
 *
 *      Call byte layout (amount offsets match HydraAugustus._patchAmounts):
 *        [0]      pallet index (Router = 67)
 *        [1]      call index   (sell = 0, buy = 1)
 *        [2..6)   asset_in     (u32, little-endian)
 *        [6..10)  asset_out    (u32, little-endian)
 *        [10..26) first u128   — amount_in (sell) / amount_out (buy)          (LE)
 *        [26..42) second u128  — min_amount_out (sell) / max_amount_in (buy)  (LE)
 *        [42]     0x00         — empty route (compact(0))
 */
library HydraRouteEncoder {
    // Call indices pinned against hydration-node: sell = #[pallet::call_index(0)],
    // buy = #[pallet::call_index(1)] (route-executor/src/lib.rs:191,218).
    // Router pallet index 67 verified vs mainnet runtime metadata (DcaDispatch.ROUTER_PALLET).
    uint8 internal constant ROUTER_PALLET = 67;
    uint8 internal constant SELL_CALL = 0;
    uint8 internal constant BUY_CALL = 1;

    /// @dev Empty route = SCALE compact(0). Triggers the router's governance-set on-chain route.
    bytes1 internal constant EMPTY_ROUTE = 0x00;

    /// @notice Encode `route_executor.sell(asset_in, asset_out, amount_in, min_amount_out, [])`.
    function encodeSell(
        uint32 assetIn,
        uint32 assetOut,
        uint128 amountIn,
        uint128 minAmountOut
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            ROUTER_PALLET,
            SELL_CALL,
            _le32(assetIn),
            _le32(assetOut),
            _le128(amountIn),
            _le128(minAmountOut),
            EMPTY_ROUTE
        );
    }

    /// @notice Encode `route_executor.buy(asset_in, asset_out, amount_out, max_amount_in, [])`.
    function encodeBuy(
        uint32 assetIn,
        uint32 assetOut,
        uint128 amountOut,
        uint128 maxAmountIn
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(
            ROUTER_PALLET,
            BUY_CALL,
            _le32(assetIn),
            _le32(assetOut),
            _le128(amountOut),
            _le128(maxAmountIn),
            EMPTY_ROUTE
        );
    }

    function _le32(uint32 x) private pure returns (bytes memory) {
        return abi.encodePacked(
            bytes1(uint8(x)),
            bytes1(uint8(x >> 8)),
            bytes1(uint8(x >> 16)),
            bytes1(uint8(x >> 24))
        );
    }

    function _le128(uint128 x) private pure returns (bytes memory b) {
        b = new bytes(16);
        for (uint256 i = 0; i < 16; i++) {
            b[i] = bytes1(uint8(x >> (8 * i)));
        }
    }
}
