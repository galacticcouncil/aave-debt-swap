// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {IParaSwapAugustus} from '../dependencies/paraswap/IParaSwapAugustus.sol';

/**
 * @title HydraAugustus
 * @notice ParaSwap Augustus-compatible DEX aggregator for Hydration substrate runtime.
 * @dev Routes sell/buy swaps through the substrate Dispatch precompile (0x0401) by
 *      forwarding SCALE-encoded `route_executor.sell` / `route_executor.buy` calls.
 *      Amounts in the SCALE payload are patched at runtime via `_patchAmounts()` so the
 *      on-chain call reflects the adapter's actual balance rather than the frontend estimate.
 *      Token interactions use low-level `call` instead of SafeERC20 because substrate
 *      precompile tokens have no EVM bytecode and would fail the `isContract` check.
 */
contract HydraAugustus is IParaSwapAugustus {
    address public immutable DISPATCH;

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

    constructor(address dispatch) {
        require(dispatch != address(0), 'ZERO_DISPATCH');
        DISPATCH = dispatch;
    }

    function getTokenTransferProxy() external view override returns (address) {
        return address(this);
    }

    /**
     * @notice Execute an exact-input swap via the substrate route executor.
     * @param tokenIn  The token to sell.
     * @param tokenOut The token to receive.
     * @param amountIn The exact amount of `tokenIn` to sell (must fit u128).
     * @param minAmountOut The minimum acceptable amount of `tokenOut` (must fit u128).
     * @param dispatchData SCALE-encoded `route_executor.sell` call; the two u128 amount
     *        fields at byte offsets [10..26) and [26..42) are overwritten by `_patchAmounts`.
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
        require(dispatchData.length >= MIN_DISPATCH_DATA_LENGTH, 'DISPATCH_DATA_TOO_SHORT');

        _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);

        uint256 balanceBefore = _safeBalanceOf(tokenOut, address(this));

        _safeApprove(tokenIn, DISPATCH, 0);
        _safeApprove(tokenIn, DISPATCH, amountIn);

        _dispatch(_patchAmounts(dispatchData, amountIn, minAmountOut));

        amountOut = _safeBalanceOf(tokenOut, address(this)) - balanceBefore;
        require(amountOut >= minAmountOut, 'INSUFFICIENT_OUTPUT');

        _safeTransfer(tokenOut, msg.sender, amountOut);

        emit Sold(tokenIn, tokenOut, amountIn, amountOut);
    }

    /**
     * @notice Execute an exact-output swap via the substrate route executor.
     * @param tokenIn  The token to spend.
     * @param tokenOut The token to receive.
     * @param maxAmountIn The maximum amount of `tokenIn` willing to spend (must fit u128).
     * @param amountOut The exact amount of `tokenOut` desired (must fit u128).
     * @param dispatchData SCALE-encoded `route_executor.buy` call; the two u128 amount
     *        fields at byte offsets [10..26) and [26..42) are overwritten by `_patchAmounts`.
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
        require(dispatchData.length >= MIN_DISPATCH_DATA_LENGTH, 'DISPATCH_DATA_TOO_SHORT');

        _safeTransferFrom(tokenIn, msg.sender, address(this), maxAmountIn);

        uint256 balanceInBefore = _safeBalanceOf(tokenIn, address(this));
        uint256 balanceOutBefore = _safeBalanceOf(tokenOut, address(this));

        _safeApprove(tokenIn, DISPATCH, 0);
        _safeApprove(tokenIn, DISPATCH, maxAmountIn);

        _dispatch(_patchAmounts(dispatchData, amountOut, maxAmountIn));

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
