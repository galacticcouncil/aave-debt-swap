// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import 'forge-std/Test.sol';
import {HydraRouteEncoder} from 'src/contracts/hydra/HydraRouteEncoder.sol';

contract HydraRouteEncoderTest is Test {
    // Sample substrate asset ids (per plan): PRIME = 43, HOLLAR = 222.
    uint32 internal constant PRIME_ID = 43;
    uint32 internal constant HOLLAR_ID = 222;

    // HydraAugustus patch offsets + the empty-route byte position.
    uint256 internal constant FIRST_AMOUNT_OFFSET = 10;
    uint256 internal constant SECOND_AMOUNT_OFFSET = 26;
    uint256 internal constant EMPTY_ROUTE_OFFSET = 42;

    /// @notice Golden vector: encodeSell(PRIME→HOLLAR, 1000, 990) = 42-byte head + 0x00 empty route.
    function test_encodeSell_goldenVector() public {
        bytes memory encoded = HydraRouteEncoder.encodeSell(PRIME_ID, HOLLAR_ID, 1000, 990);

        bytes memory expected = hex'43002b000000de000000e8030000000000000000000000000000de03000000000000000000000000000000';
        //  43            pallet 67
        //  00            sell call 0
        //  2b000000      asset_in  = 43  (LE u32)
        //  de000000      asset_out = 222 (LE u32)
        //  e803..(16)    amount_in = 1000 (LE u128)
        //  de03..(16)    min_out   = 990  (LE u128)
        //  00            empty route (compact(0)) -> router uses its on-chain gov route
        assertEq(encoded, expected, 'sell byte layout mismatch');
        assertEq(encoded.length, 43, 'head(42) + empty route(1)');
    }

    /// @notice Golden vector for buy: call index 1, amounts (amount_out, max_amount_in), + 0x00.
    function test_encodeBuy_goldenVector() public {
        bytes memory encoded = HydraRouteEncoder.encodeBuy(PRIME_ID, HOLLAR_ID, 500, 510);

        bytes memory expected = hex'43012b000000de000000f4010000000000000000000000000000fe01000000000000000000000000000000';
        assertEq(encoded, expected, 'buy byte layout mismatch');
        assertEq(uint8(encoded[1]), 1, 'buy call index');
    }

    /// @notice Amounts must land at HydraAugustus's patch offsets, and the call ends in 0x00.
    function test_encodeSell_amountsAtPatchOffsetsAndEmptyRoute() public {
        uint128 amountIn = 123456789;
        uint128 minOut = 987654321;
        bytes memory encoded = HydraRouteEncoder.encodeSell(PRIME_ID, HOLLAR_ID, amountIn, minOut);

        assertEq(uint8(encoded[0]), 67, 'pallet');
        assertEq(uint8(encoded[1]), 0, 'sell call');
        assertEq(_le128At(encoded, FIRST_AMOUNT_OFFSET), amountIn, 'amount_in offset');
        assertEq(_le128At(encoded, SECOND_AMOUNT_OFFSET), minOut, 'min_out offset');
        assertEq(uint8(encoded[EMPTY_ROUTE_OFFSET]), 0, 'trailing empty-route byte');
    }

    /// @notice buy orders (amount_out, max_amount_in) at the two u128 offsets.
    function test_encodeBuy_amountOrder() public {
        uint128 amountOut = 500;
        uint128 maxAmountIn = 510;
        bytes memory encoded = HydraRouteEncoder.encodeBuy(PRIME_ID, HOLLAR_ID, amountOut, maxAmountIn);
        assertEq(_le128At(encoded, FIRST_AMOUNT_OFFSET), amountOut, 'amount_out first');
        assertEq(_le128At(encoded, SECOND_AMOUNT_OFFSET), maxAmountIn, 'max_in second');
    }

    function _le128At(bytes memory b, uint256 o) internal pure returns (uint128 x) {
        for (uint256 i = 0; i < 16; i++) {
            x |= uint128(uint8(b[o + i])) << uint128(8 * i);
        }
    }
}
