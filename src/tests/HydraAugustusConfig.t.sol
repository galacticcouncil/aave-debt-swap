// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import 'forge-std/Test.sol';
import {HydraAugustus} from 'src/contracts/hydra/HydraAugustus.sol';

contract HydraAugustusConfigTest is Test {
    event AssetIdSet(address indexed token, uint32 indexed assetId);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    HydraAugustus internal augustus;

    address internal constant DISPATCH = address(0x0401);
    address internal constant PRIME = address(0xA11CE);
    uint32 internal constant PRIME_ID = 43;
    address internal stranger = address(0xBAD);

    function setUp() public {
        augustus = new HydraAugustus(DISPATCH); // owner = this
    }

    // ── ownership ─────────────────────────────────────────────────────────

    function test_constructor_setsDeployerAsOwner() public {
        assertEq(augustus.owner(), address(this));
    }

    function test_transferOwnership() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(address(this), stranger);
        augustus.transferOwnership(stranger);
        assertEq(augustus.owner(), stranger);

        // old owner loses configuration rights
        vm.expectRevert(bytes('ONLY_OWNER'));
        augustus.setAssetId(PRIME, PRIME_ID);
    }

    function test_revert_transferOwnership_zero() public {
        vm.expectRevert(bytes('ZERO_ADDRESS'));
        augustus.transferOwnership(address(0));
    }

    function test_revert_transferOwnership_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert(bytes('ONLY_OWNER'));
        augustus.transferOwnership(stranger);
    }

    // ── asset id map ──────────────────────────────────────────────────────

    function test_setAssetId() public {
        vm.expectEmit(true, true, false, true);
        emit AssetIdSet(PRIME, PRIME_ID);
        augustus.setAssetId(PRIME, PRIME_ID);
        assertEq(augustus.assetId(PRIME), PRIME_ID);
    }

    function test_revert_setAssetId_zeroToken() public {
        vm.expectRevert(bytes('ZERO_ADDRESS'));
        augustus.setAssetId(address(0), PRIME_ID);
    }

    function test_revert_setAssetId_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert(bytes('ONLY_OWNER'));
        augustus.setAssetId(PRIME, PRIME_ID);
    }
}
