// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

contract MockDispatchPrecompile {
    uint8 public constant SELL_CALL_INDEX = 0;
    uint8 public constant BUY_CALL_INDEX = 1;

    mapping(uint32 => address) public assetIdToToken;
    uint256 public rateNumerator;
    uint256 public rateDenominator;

    bool public shouldRevert;

    function setAssetMapping(uint32 assetId, address token) external {
        assetIdToToken[assetId] = token;
    }

    function setRate(uint256 numerator, uint256 denominator) external {
        rateNumerator = numerator;
        rateDenominator = denominator;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    fallback() external {
        require(!shouldRevert, 'MOCK_DISPATCH_REVERTED');
        require(msg.data.length >= 42, 'DATA_TOO_SHORT');

        uint8 callIndex = uint8(msg.data[1]);

        uint32 assetInId = _readU32LE(2);
        uint32 assetOutId = _readU32LE(6);
        uint256 firstAmount = _readU128LE(10);

        address tokenIn = assetIdToToken[assetInId];
        address tokenOut = assetIdToToken[assetOutId];
        require(tokenIn != address(0) && tokenOut != address(0), 'UNKNOWN_ASSET');

        if (callIndex == SELL_CALL_INDEX) {
            uint256 amountOut = (firstAmount * rateNumerator) / rateDenominator;
            IERC20(tokenIn).transferFrom(msg.sender, address(this), firstAmount);
            IERC20(tokenOut).transfer(msg.sender, amountOut);
        } else if (callIndex == BUY_CALL_INDEX) {
            uint256 amountIn = (firstAmount * rateDenominator) / rateNumerator;
            IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
            IERC20(tokenOut).transfer(msg.sender, firstAmount);
        } else {
            revert('UNKNOWN_CALL_INDEX');
        }
    }

    function _readU32LE(uint256 offset) internal pure returns (uint32 result) {
        result =
            uint32(uint8(msg.data[offset])) |
            (uint32(uint8(msg.data[offset + 1])) << 8) |
            (uint32(uint8(msg.data[offset + 2])) << 16) |
            (uint32(uint8(msg.data[offset + 3])) << 24);
    }

    function _readU128LE(uint256 offset) internal pure returns (uint256 result) {
        for (uint256 i = 0; i < 16; i++) {
            result |= uint256(uint8(msg.data[offset + i])) << (i * 8);
        }
    }
}
