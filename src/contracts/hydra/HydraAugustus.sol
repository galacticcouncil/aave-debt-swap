// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {IParaSwapAugustus} from '../dependencies/paraswap/IParaSwapAugustus.sol';
import {HydraRouteEncoder} from './HydraRouteEncoder.sol';

/**
 * @title HydraAugustus
 * @notice ParaSwap Augustus-compatible DEX aggregator for Hydration substrate runtime.
 * @dev Routes sell/buy swaps through the substrate Dispatch precompile (0x0401) by
 *      forwarding a SCALE-encoded `route_executor.sell` / `route_executor.buy` call. The
 *      call is either built here from a governance-set `address → assetId` map with an
 *      EMPTY route — so Hydration's router resolves the pools from its own on-chain
 *      governance storage (`set_route`) — or supplied by the caller as `dispatchData` and
 *      amount-patched via `_patchAmounts()`. Token interactions use low-level `call` instead
 *      of SafeERC20 because substrate precompile tokens have no EVM bytecode and would fail
 *      the `isContract` check.
 */
contract HydraAugustus is IParaSwapAugustus {
    address public immutable DISPATCH;

    /// @notice Governance owner permitted to configure asset ids and routes.
    address public owner;

    /// @notice EVM token address → Hydration substrate asset id (governance-set).
    /// @dev Consumed by the empty-`dispatchData` path, which builds the `route_executor`
    ///      call from asset ids. ERC-20s like HOLLAR (asset 222) don't encode their id
    ///      in-address the way Omnipool-style tokens like PRIME (asset 43) do, so the map
    ///      is required. A token must be registered (non-zero id) to swap via that path;
    ///      the route itself lives on the router, not here.
    mapping(address => uint32) public assetId;

    uint256 internal constant SCALE_FIRST_AMOUNT_OFFSET = 10;
    uint256 internal constant SCALE_SECOND_AMOUNT_OFFSET = 26;
    uint256 internal constant MIN_DISPATCH_DATA_LENGTH = 42;
    uint256 internal constant MAX_UINT128 = type(uint128).max;

    event Sold(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event Bought(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event AssetIdSet(address indexed token, uint32 indexed assetId);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, 'ONLY_OWNER');
        _;
    }

    constructor(address dispatch) {
        require(dispatch != address(0), 'ZERO_DISPATCH');
        DISPATCH = dispatch;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ── Governance configuration ──────────────────────────────────────────

    /**
     * @notice Map an EVM token address to its Hydration substrate asset id.
     * @dev Consumed by the empty-`dispatchData` path in `sell`/`buy`. A token must be
     *      registered here (non-zero id) to swap via that path, so HDX (asset 0) is not
     *      reachable this way — pass explicit `dispatchData` for it. The route is resolved
     *      by the on-chain router, not stored here.
     * @param token The ERC-20 / precompile token address.
     * @param id    The substrate asset id used inside the SCALE call.
     */
    function setAssetId(address token, uint32 id) external onlyOwner {
        require(token != address(0), 'ZERO_ADDRESS');
        assetId[token] = id;
        emit AssetIdSet(token, id);
    }

    /**
     * @notice Transfer governance ownership (e.g. deployer → Hydration governance).
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), 'ZERO_ADDRESS');
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function getTokenTransferProxy() external view override returns (address) {
        return address(this);
    }

    /**
     * @notice Execute an exact-input swap via the substrate route executor.
     * @dev Two modes:
     *      - empty `dispatchData` → build `route_executor.sell(assetId[tokenIn],
     *        assetId[tokenOut], amountIn, minAmountOut, [])` with an EMPTY route, so the
     *        router uses its governance-set on-chain route (keeper path);
     *      - non-empty `dispatchData` → treat it as a caller-supplied SCALE call and patch
     *        the amounts at offsets [10..26)/[26..42) (frontend / debt-swap path).
     * @param tokenIn  The token to sell.
     * @param tokenOut The token to receive.
     * @param amountIn The exact amount of `tokenIn` to sell (must fit u128).
     * @param minAmountOut The minimum acceptable amount of `tokenOut` (must fit u128).
     * @param dispatchData Empty to build from the asset-id map, or a SCALE-encoded
     *        `route_executor.sell` call whose amounts are patched.
     * @return amountOut The amount of `tokenOut` received.
     */
    function sell(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata dispatchData
    ) external returns (uint256 amountOut) {
        require(amountIn > 0, 'ZERO_AMOUNT_IN');
        require(amountIn <= MAX_UINT128, 'AMOUNT_OVERFLOW_UINT128');
        require(minAmountOut <= MAX_UINT128, 'AMOUNT_OVERFLOW_UINT128');

        bytes memory callData = _buildSellCall(tokenIn, tokenOut, amountIn, minAmountOut, dispatchData);

        _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);

        uint256 balanceBefore = _safeBalanceOf(tokenOut, address(this));

        _safeApprove(tokenIn, DISPATCH, 0);
        _safeApprove(tokenIn, DISPATCH, amountIn);

        _dispatch(callData);

        amountOut = _safeBalanceOf(tokenOut, address(this)) - balanceBefore;
        require(amountOut >= minAmountOut, 'INSUFFICIENT_OUTPUT');

        _safeTransfer(tokenOut, msg.sender, amountOut);

        emit Sold(tokenIn, tokenOut, amountIn, amountOut);
    }

    /**
     * @notice Execute an exact-output swap via the substrate route executor.
     * @dev Two modes (see `sell`): empty `dispatchData` → build
     *      `route_executor.buy(assetId[tokenIn], assetId[tokenOut], amountOut, maxAmountIn, [])`
     *      with an EMPTY route; non-empty → patch amounts into the caller-supplied call.
     * @dev ⚠️ Param order here is `(maxAmountIn, amountOut)` — the debt-swap adapter
     *      convention, and the REVERSE of Propeller's `ISwapper.buy(…, amountOut, maxIn, …)`,
     *      which shares the same 4-arg selector. Propeller only ever calls `sell()`
     *      (verified: `CollateralVault.compound` is the sole swapper caller), so this
     *      divergence is intentional. Do NOT route Propeller's `buy` here via the ISwapper
     *      cast without first aligning the two uint256 args, or they will be swapped silently.
     * @param tokenIn  The token to spend.
     * @param tokenOut The token to receive.
     * @param maxAmountIn The maximum amount of `tokenIn` willing to spend (must fit u128).
     * @param amountOut The exact amount of `tokenOut` desired (must fit u128).
     * @param dispatchData Empty to build from the asset-id map, or a SCALE-encoded
     *        `route_executor.buy` call whose amounts are patched.
     * @return amountIn The actual amount of `tokenIn` consumed.
     */
    function buy(
        address tokenIn,
        address tokenOut,
        uint256 maxAmountIn,
        uint256 amountOut,
        bytes calldata dispatchData
    ) external returns (uint256 amountIn) {
        require(maxAmountIn > 0, 'ZERO_AMOUNT_IN');
        require(maxAmountIn <= MAX_UINT128, 'AMOUNT_OVERFLOW_UINT128');
        require(amountOut <= MAX_UINT128, 'AMOUNT_OVERFLOW_UINT128');

        bytes memory callData = _buildBuyCall(tokenIn, tokenOut, amountOut, maxAmountIn, dispatchData);

        _safeTransferFrom(tokenIn, msg.sender, address(this), maxAmountIn);

        uint256 balanceInBefore = _safeBalanceOf(tokenIn, address(this));
        uint256 balanceOutBefore = _safeBalanceOf(tokenOut, address(this));

        _safeApprove(tokenIn, DISPATCH, 0);
        _safeApprove(tokenIn, DISPATCH, maxAmountIn);

        _dispatch(callData);

        amountIn = balanceInBefore - _safeBalanceOf(tokenIn, address(this));
        uint256 received = _safeBalanceOf(tokenOut, address(this)) - balanceOutBefore;

        require(received >= amountOut, 'INSUFFICIENT_OUTPUT');

        _safeTransfer(tokenOut, msg.sender, received);
        if (amountIn < maxAmountIn) {
            _safeTransfer(tokenIn, msg.sender, maxAmountIn - amountIn);
        }

        emit Bought(tokenIn, tokenOut, amountIn, received);
    }

    /**
     * @dev Build the SCALE call bytes for a sell: from the governance asset-id map with an
     *      EMPTY route when `dispatchData` is empty (keeper path), else patch the amounts
     *      into the caller-supplied SCALE call (frontend / debt-swap path).
     */
    function _buildSellCall(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata dispatchData
    ) internal view returns (bytes memory) {
        if (dispatchData.length == 0) {
            (uint32 inId, uint32 outId) = _resolveAssetIds(tokenIn, tokenOut);
            return HydraRouteEncoder.encodeSell(inId, outId, uint128(amountIn), uint128(minAmountOut));
        }
        require(dispatchData.length >= MIN_DISPATCH_DATA_LENGTH, 'DISPATCH_DATA_TOO_SHORT');
        return _patchAmounts(dispatchData, amountIn, minAmountOut);
    }

    /**
     * @dev Build the SCALE call bytes for a buy (see `_buildSellCall`).
     */
    function _buildBuyCall(
        address tokenIn,
        address tokenOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        bytes calldata dispatchData
    ) internal view returns (bytes memory) {
        if (dispatchData.length == 0) {
            (uint32 inId, uint32 outId) = _resolveAssetIds(tokenIn, tokenOut);
            return HydraRouteEncoder.encodeBuy(inId, outId, uint128(amountOut), uint128(maxAmountIn));
        }
        require(dispatchData.length >= MIN_DISPATCH_DATA_LENGTH, 'DISPATCH_DATA_TOO_SHORT');
        return _patchAmounts(dispatchData, amountOut, maxAmountIn);
    }

    /**
     * @dev Resolve the substrate asset ids for a token pair. Both must be registered
     *      (non-zero) via `setAssetId`; HDX (asset 0) is intentionally not reachable
     *      through the empty-`dispatchData` path.
     */
    function _resolveAssetIds(address tokenIn, address tokenOut)
        internal
        view
        returns (uint32 inId, uint32 outId)
    {
        inId = assetId[tokenIn];
        outId = assetId[tokenOut];
        require(inId != 0 && outId != 0, 'ASSET_NOT_REGISTERED');
    }

    /**
     * @dev Patch the two u128 amount fields inside SCALE-encoded dispatch data.
     *
     * The adapter may overwrite ABI-level amounts at runtime (e.g. "swap all balance" reads
     * the actual debt/collateral balance on-chain). But the SCALE-encoded `dispatchData` still
     * holds the frontend's original estimate. This function overwrites the two little-endian
     * u128 fields so the Dispatch precompile receives the correct values.
     *
     * SCALE byte layout (route_executor.sell / route_executor.buy):
     *   [0..2)   pallet + call index
     *   [2..10)  asset_in / asset_out identifiers
     *   [10..26) first u128  — amount_in (sell) or amount_out (buy)
     *   [26..42) second u128 — min_amount_out (sell) or max_amount_in (buy)
     *   [42..)   route data
     *
     * @param dispatchData The original SCALE-encoded call (minimum 42 bytes).
     * @param firstAmount  Value to write at bytes [10..26) in little-endian u128.
     * @param secondAmount Value to write at bytes [26..42) in little-endian u128.
     * @return data The patched SCALE bytes, ready for `_dispatch()`.
     */
    function _patchAmounts(
        bytes calldata dispatchData,
        uint256 firstAmount,
        uint256 secondAmount
    ) internal pure returns (bytes memory data) {
        data = bytes(dispatchData);

        assembly {
            let ptr := add(data, 32)

            let firstAmountPtr := add(ptr, SCALE_FIRST_AMOUNT_OFFSET)
            mstore8(firstAmountPtr, and(firstAmount, 0xff))
            mstore8(add(firstAmountPtr, 1), and(shr(8, firstAmount), 0xff))
            mstore8(add(firstAmountPtr, 2), and(shr(16, firstAmount), 0xff))
            mstore8(add(firstAmountPtr, 3), and(shr(24, firstAmount), 0xff))
            mstore8(add(firstAmountPtr, 4), and(shr(32, firstAmount), 0xff))
            mstore8(add(firstAmountPtr, 5), and(shr(40, firstAmount), 0xff))
            mstore8(add(firstAmountPtr, 6), and(shr(48, firstAmount), 0xff))
            mstore8(add(firstAmountPtr, 7), and(shr(56, firstAmount), 0xff))
            mstore8(add(firstAmountPtr, 8), and(shr(64, firstAmount), 0xff))
            mstore8(add(firstAmountPtr, 9), and(shr(72, firstAmount), 0xff))
            mstore8(add(firstAmountPtr, 10), and(shr(80, firstAmount), 0xff))
            mstore8(add(firstAmountPtr, 11), and(shr(88, firstAmount), 0xff))
            mstore8(add(firstAmountPtr, 12), and(shr(96, firstAmount), 0xff))
            mstore8(add(firstAmountPtr, 13), and(shr(104, firstAmount), 0xff))
            mstore8(add(firstAmountPtr, 14), and(shr(112, firstAmount), 0xff))
            mstore8(add(firstAmountPtr, 15), and(shr(120, firstAmount), 0xff))

            let secondAmountPtr := add(ptr, SCALE_SECOND_AMOUNT_OFFSET)
            mstore8(secondAmountPtr, and(secondAmount, 0xff))
            mstore8(add(secondAmountPtr, 1), and(shr(8, secondAmount), 0xff))
            mstore8(add(secondAmountPtr, 2), and(shr(16, secondAmount), 0xff))
            mstore8(add(secondAmountPtr, 3), and(shr(24, secondAmount), 0xff))
            mstore8(add(secondAmountPtr, 4), and(shr(32, secondAmount), 0xff))
            mstore8(add(secondAmountPtr, 5), and(shr(40, secondAmount), 0xff))
            mstore8(add(secondAmountPtr, 6), and(shr(48, secondAmount), 0xff))
            mstore8(add(secondAmountPtr, 7), and(shr(56, secondAmount), 0xff))
            mstore8(add(secondAmountPtr, 8), and(shr(64, secondAmount), 0xff))
            mstore8(add(secondAmountPtr, 9), and(shr(72, secondAmount), 0xff))
            mstore8(add(secondAmountPtr, 10), and(shr(80, secondAmount), 0xff))
            mstore8(add(secondAmountPtr, 11), and(shr(88, secondAmount), 0xff))
            mstore8(add(secondAmountPtr, 12), and(shr(96, secondAmount), 0xff))
            mstore8(add(secondAmountPtr, 13), and(shr(104, secondAmount), 0xff))
            mstore8(add(secondAmountPtr, 14), and(shr(112, secondAmount), 0xff))
            mstore8(add(secondAmountPtr, 15), and(shr(120, secondAmount), 0xff))
        }
    }

    /// @dev Low-level balanceOf bypassing isContract check for substrate precompile tokens
    function _safeBalanceOf(address token, address account) internal view returns (uint256 balance) {
        (bool success, bytes memory returndata) = token.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, account)
        );
        require(success && returndata.length >= 32, 'BALANCE_OF_FAILED');
        balance = abi.decode(returndata, (uint256));
    }

    /// @dev Low-level approve bypassing isContract check for substrate precompile tokens
    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory returndata) = token.call(
            abi.encodeWithSelector(IERC20.approve.selector, spender, amount)
        );
        require(success && (returndata.length == 0 || abi.decode(returndata, (bool))), 'APPROVE_FAILED');
    }

    /// @dev Low-level transfer bypassing isContract check for substrate precompile tokens
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory returndata) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(success && (returndata.length == 0 || abi.decode(returndata, (bool))), 'TRANSFER_FAILED');
    }

    /// @dev Low-level transferFrom bypassing isContract check for substrate precompile tokens
    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory returndata) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        require(success && (returndata.length == 0 || abi.decode(returndata, (bool))), 'TRANSFER_FROM_FAILED');
    }

    /**
     * @dev Forward a SCALE-encoded extrinsic to the substrate Dispatch precompile.
     * @param data The fully encoded call bytes (pallet index + call data).
     */
    function _dispatch(bytes memory data) internal {
        (bool success, bytes memory returnData) = DISPATCH.call(data);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
