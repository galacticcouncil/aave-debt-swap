// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {SafeERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/SafeERC20.sol';
import {IParaSwapAugustus} from '../dependencies/paraswap/IParaSwapAugustus.sol';

contract HydraAugustus is IParaSwapAugustus {
    using SafeERC20 for IERC20;

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

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).safeApprove(DISPATCH, 0);
        IERC20(tokenIn).safeApprove(DISPATCH, amountIn);

        _dispatch(_patchAmounts(dispatchData, amountIn, minAmountOut));

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - balanceBefore;
        require(amountOut >= minAmountOut, 'INSUFFICIENT_OUTPUT');

        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        emit Sold(tokenIn, tokenOut, amountIn, amountOut);
    }

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

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), maxAmountIn);

        uint256 balanceInBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 balanceOutBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).safeApprove(DISPATCH, 0);
        IERC20(tokenIn).safeApprove(DISPATCH, maxAmountIn);

        _dispatch(_patchAmounts(dispatchData, amountOut, maxAmountIn));

        amountIn = balanceInBefore - IERC20(tokenIn).balanceOf(address(this));
        uint256 received = IERC20(tokenOut).balanceOf(address(this)) - balanceOutBefore;

        require(received >= amountOut, 'INSUFFICIENT_OUTPUT');

        IERC20(tokenOut).safeTransfer(msg.sender, received);
        if (amountIn < maxAmountIn) {
            IERC20(tokenIn).safeTransfer(msg.sender, maxAmountIn - amountIn);
        }

        emit Bought(tokenIn, tokenOut, amountIn, received);
    }

    // The adapter may overwrite ABI-level amounts at runtime (e.g. "swap all balance" reads
    // the actual debt/collateral balance on-chain). But the SCALE-encoded dispatchData still
    // holds the frontend's original estimate. This function patches the two u128 amount fields
    // in the SCALE bytes (little-endian at offsets [10..26) and [26..42)) so the Dispatch
    // precompile receives the correct values.
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

    function _dispatch(bytes memory data) internal {
        (bool success, bytes memory returnData) = DISPATCH.call(data);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
