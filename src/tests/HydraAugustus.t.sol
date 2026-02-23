// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import 'forge-std/Test.sol';
import {HydraAugustus} from 'src/contracts/hydra/HydraAugustus.sol';
import {MockDispatchPrecompile} from './mocks/MockDispatchPrecompile.sol';
import {MockERC20} from './mocks/MockERC20.sol';

contract HydraAugustusTest is Test {
    event Sold(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event Bought(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);

    HydraAugustus internal augustus;
    MockDispatchPrecompile internal mockDispatch;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    uint32 internal constant ASSET_ID_A = 1;
    uint32 internal constant ASSET_ID_B = 2;
    uint8 internal constant SELL_CALL_INDEX = 0;
    uint8 internal constant BUY_CALL_INDEX = 1;
    uint8 internal constant PALLET_INDEX = 42;

    address internal caller;

    function setUp() public {
        mockDispatch = new MockDispatchPrecompile();
        augustus = new HydraAugustus(address(mockDispatch));

        tokenA = new MockERC20('Token A', 'TKA', 18);
        tokenB = new MockERC20('Token B', 'TKB', 18);

        mockDispatch.setAssetMapping(ASSET_ID_A, address(tokenA));
        mockDispatch.setAssetMapping(ASSET_ID_B, address(tokenB));
        mockDispatch.setRate(1e18, 1e18);

        caller = address(0xA11CE);
    }

    function test_getTokenTransferProxy() public {
        assertEq(augustus.getTokenTransferProxy(), address(augustus));
    }

    function test_sell_basic() public {
        uint256 amountIn = 1000e18;
        uint256 minAmountOut = 900e18;

        tokenA.mint(caller, amountIn);
        tokenB.mint(address(mockDispatch), amountIn);

        vm.startPrank(caller);
        tokenA.approve(address(augustus), amountIn);

        bytes memory dispatchData = _buildSellDispatchData(ASSET_ID_A, ASSET_ID_B, amountIn, minAmountOut);

        uint256 amountOut = augustus.sell(
            address(tokenA),
            address(tokenB),
            amountIn,
            minAmountOut,
            dispatchData
        );
        vm.stopPrank();

        assertEq(amountOut, amountIn);
        assertEq(tokenA.balanceOf(caller), 0);
        assertEq(tokenB.balanceOf(caller), amountIn);
        assertEq(tokenA.balanceOf(address(augustus)), 0);
        assertEq(tokenB.balanceOf(address(augustus)), 0);
    }

    function test_sell_withExchangeRate() public {
        mockDispatch.setRate(95, 100);

        uint256 amountIn = 1000e18;
        uint256 expectedOut = 950e18;
        uint256 minAmountOut = 900e18;

        tokenA.mint(caller, amountIn);
        tokenB.mint(address(mockDispatch), expectedOut);

        vm.startPrank(caller);
        tokenA.approve(address(augustus), amountIn);

        bytes memory dispatchData = _buildSellDispatchData(ASSET_ID_A, ASSET_ID_B, amountIn, minAmountOut);

        uint256 amountOut = augustus.sell(
            address(tokenA),
            address(tokenB),
            amountIn,
            minAmountOut,
            dispatchData
        );
        vm.stopPrank();

        assertEq(amountOut, expectedOut);
        assertEq(tokenB.balanceOf(caller), expectedOut);
    }

    function test_sell_emitsEvent() public {
        uint256 amountIn = 500e18;
        uint256 minAmountOut = 400e18;

        tokenA.mint(caller, amountIn);
        tokenB.mint(address(mockDispatch), amountIn);

        vm.startPrank(caller);
        tokenA.approve(address(augustus), amountIn);

        bytes memory dispatchData = _buildSellDispatchData(ASSET_ID_A, ASSET_ID_B, amountIn, minAmountOut);

        vm.expectEmit(true, true, false, true);
        emit Sold(address(tokenA), address(tokenB), amountIn, amountIn);

        augustus.sell(address(tokenA), address(tokenB), amountIn, minAmountOut, dispatchData);
        vm.stopPrank();
    }

    function test_revert_sell_zeroAmount() public {
        bytes memory dispatchData = _buildSellDispatchData(ASSET_ID_A, ASSET_ID_B, 0, 0);

        vm.expectRevert(bytes('ZERO_AMOUNT_IN'));
        augustus.sell(address(tokenA), address(tokenB), 0, 0, dispatchData);
    }

    function test_revert_sell_amountOverflowUint128() public {
        uint256 overflowAmount = uint256(type(uint128).max) + 1;
        bytes memory dispatchData = _buildSellDispatchData(ASSET_ID_A, ASSET_ID_B, 1e18, 1e18);

        vm.expectRevert(bytes('AMOUNT_OVERFLOW_UINT128'));
        augustus.sell(address(tokenA), address(tokenB), overflowAmount, 1e18, dispatchData);
    }

    function test_revert_sell_dispatchDataTooShort() public {
        bytes memory shortData = new bytes(41);

        vm.expectRevert(bytes('DISPATCH_DATA_TOO_SHORT'));
        augustus.sell(address(tokenA), address(tokenB), 1e18, 1e18, shortData);
    }

    function test_revert_sell_dispatchReverts() public {
        uint256 amountIn = 100e18;
        tokenA.mint(caller, amountIn);

        mockDispatch.setShouldRevert(true);

        vm.startPrank(caller);
        tokenA.approve(address(augustus), amountIn);

        bytes memory dispatchData = _buildSellDispatchData(ASSET_ID_A, ASSET_ID_B, amountIn, 0);

        vm.expectRevert(bytes('MOCK_DISPATCH_REVERTED'));
        augustus.sell(address(tokenA), address(tokenB), amountIn, 0, dispatchData);
        vm.stopPrank();
    }

    function test_revert_sell_insufficientOutput() public {
        mockDispatch.setRate(50, 100);

        uint256 amountIn = 1000e18;
        uint256 minAmountOut = 600e18;

        tokenA.mint(caller, amountIn);
        tokenB.mint(address(mockDispatch), 500e18);

        vm.startPrank(caller);
        tokenA.approve(address(augustus), amountIn);

        bytes memory dispatchData = _buildSellDispatchData(ASSET_ID_A, ASSET_ID_B, amountIn, minAmountOut);

        vm.expectRevert(bytes('INSUFFICIENT_OUTPUT'));
        augustus.sell(address(tokenA), address(tokenB), amountIn, minAmountOut, dispatchData);
        vm.stopPrank();
    }

    function test_buy_basic() public {
        uint256 maxAmountIn = 1100e18;
        uint256 amountOut = 1000e18;

        tokenA.mint(caller, maxAmountIn);
        tokenB.mint(address(mockDispatch), amountOut);

        vm.startPrank(caller);
        tokenA.approve(address(augustus), maxAmountIn);

        bytes memory dispatchData = _buildBuyDispatchData(ASSET_ID_A, ASSET_ID_B, amountOut, maxAmountIn);

        uint256 amountIn = augustus.buy(
            address(tokenA),
            address(tokenB),
            maxAmountIn,
            amountOut,
            dispatchData
        );
        vm.stopPrank();

        assertEq(amountIn, amountOut);
        assertEq(tokenB.balanceOf(caller), amountOut);
        uint256 refund = maxAmountIn - amountIn;
        assertEq(tokenA.balanceOf(caller), refund);
        assertEq(tokenA.balanceOf(address(augustus)), 0);
        assertEq(tokenB.balanceOf(address(augustus)), 0);
    }

    function test_buy_noRefund() public {
        uint256 maxAmountIn = 1000e18;
        uint256 amountOut = 1000e18;

        tokenA.mint(caller, maxAmountIn);
        tokenB.mint(address(mockDispatch), amountOut);

        vm.startPrank(caller);
        tokenA.approve(address(augustus), maxAmountIn);

        bytes memory dispatchData = _buildBuyDispatchData(ASSET_ID_A, ASSET_ID_B, amountOut, maxAmountIn);

        uint256 amountIn = augustus.buy(
            address(tokenA),
            address(tokenB),
            maxAmountIn,
            amountOut,
            dispatchData
        );
        vm.stopPrank();

        assertEq(amountIn, maxAmountIn);
        assertEq(tokenA.balanceOf(caller), 0);
        assertEq(tokenB.balanceOf(caller), amountOut);
        assertEq(tokenA.balanceOf(address(augustus)), 0);
    }

    function test_buy_withExchangeRate() public {
        mockDispatch.setRate(2, 1);

        uint256 amountOut = 1000e18;
        uint256 expectedIn = 500e18;
        uint256 maxAmountIn = 600e18;

        tokenA.mint(caller, maxAmountIn);
        tokenB.mint(address(mockDispatch), amountOut);

        vm.startPrank(caller);
        tokenA.approve(address(augustus), maxAmountIn);

        bytes memory dispatchData = _buildBuyDispatchData(ASSET_ID_A, ASSET_ID_B, amountOut, maxAmountIn);

        uint256 amountIn = augustus.buy(
            address(tokenA),
            address(tokenB),
            maxAmountIn,
            amountOut,
            dispatchData
        );
        vm.stopPrank();

        assertEq(amountIn, expectedIn);
        assertEq(tokenB.balanceOf(caller), amountOut);
        assertEq(tokenA.balanceOf(caller), maxAmountIn - expectedIn);
        assertEq(tokenA.balanceOf(address(augustus)), 0);
    }

    function test_buy_emitsEvent() public {
        uint256 maxAmountIn = 1000e18;
        uint256 amountOut = 1000e18;

        tokenA.mint(caller, maxAmountIn);
        tokenB.mint(address(mockDispatch), amountOut);

        vm.startPrank(caller);
        tokenA.approve(address(augustus), maxAmountIn);

        bytes memory dispatchData = _buildBuyDispatchData(ASSET_ID_A, ASSET_ID_B, amountOut, maxAmountIn);

        vm.expectEmit(true, true, false, true);
        emit Bought(address(tokenA), address(tokenB), maxAmountIn, amountOut);

        augustus.buy(address(tokenA), address(tokenB), maxAmountIn, amountOut, dispatchData);
        vm.stopPrank();
    }

    function test_revert_buy_zeroAmount() public {
        bytes memory dispatchData = _buildBuyDispatchData(ASSET_ID_A, ASSET_ID_B, 1e18, 0);

        vm.expectRevert(bytes('ZERO_AMOUNT_IN'));
        augustus.buy(address(tokenA), address(tokenB), 0, 1e18, dispatchData);
    }

    function test_revert_buy_dispatchReverts() public {
        uint256 maxAmountIn = 100e18;
        tokenA.mint(caller, maxAmountIn);

        mockDispatch.setShouldRevert(true);

        vm.startPrank(caller);
        tokenA.approve(address(augustus), maxAmountIn);

        bytes memory dispatchData = _buildBuyDispatchData(ASSET_ID_A, ASSET_ID_B, 50e18, maxAmountIn);

        vm.expectRevert(bytes('MOCK_DISPATCH_REVERTED'));
        augustus.buy(address(tokenA), address(tokenB), maxAmountIn, 50e18, dispatchData);
        vm.stopPrank();
    }

    function test_revert_constructor_zeroDispatch() public {
        vm.expectRevert(bytes('ZERO_DISPATCH'));
        new HydraAugustus(address(0));
    }

    function _buildSellDispatchData(
        uint32 assetInId,
        uint32 assetOutId,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal pure returns (bytes memory data) {
        data = new bytes(42);
        data[0] = bytes1(PALLET_INDEX);
        data[1] = bytes1(SELL_CALL_INDEX);
        _writeU32LE(data, 2, assetInId);
        _writeU32LE(data, 6, assetOutId);
        _writeU128LE(data, 10, amountIn);
        _writeU128LE(data, 26, minAmountOut);
    }

    function _buildBuyDispatchData(
        uint32 assetInId,
        uint32 assetOutId,
        uint256 amountOut,
        uint256 maxAmountIn
    ) internal pure returns (bytes memory data) {
        data = new bytes(42);
        data[0] = bytes1(PALLET_INDEX);
        data[1] = bytes1(BUY_CALL_INDEX);
        _writeU32LE(data, 2, assetInId);
        _writeU32LE(data, 6, assetOutId);
        _writeU128LE(data, 10, amountOut);
        _writeU128LE(data, 26, maxAmountIn);
    }

    function _writeU32LE(bytes memory data, uint256 offset, uint32 value) internal pure {
        data[offset] = bytes1(uint8(value));
        data[offset + 1] = bytes1(uint8(value >> 8));
        data[offset + 2] = bytes1(uint8(value >> 16));
        data[offset + 3] = bytes1(uint8(value >> 24));
    }

    function _writeU128LE(bytes memory data, uint256 offset, uint256 value) internal pure {
        for (uint256 i = 0; i < 16; i++) {
            data[offset + i] = bytes1(uint8(value >> (i * 8)));
        }
    }
}
