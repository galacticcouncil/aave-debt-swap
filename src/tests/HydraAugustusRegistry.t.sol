// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import 'forge-std/Test.sol';
import {HydraAugustusRegistry} from 'src/contracts/hydra/HydraAugustusRegistry.sol';

contract HydraAugustusRegistryTest is Test {
    HydraAugustusRegistry internal registry;
    address internal augustus = address(0xBEEF);

    function setUp() public {
        registry = new HydraAugustusRegistry(augustus);
    }

    function test_isValidAugustus_registered() public {
        assertTrue(registry.isValidAugustus(augustus));
    }

    function test_isValidAugustus_unregistered() public {
        assertFalse(registry.isValidAugustus(address(0xDEAD)));
    }

    function test_isValidAugustus_zeroAddress() public {
        assertFalse(registry.isValidAugustus(address(0)));
    }

    function test_setAugustus_add() public {
        address newAugustus = address(0xCAFE);
        registry.setAugustus(newAugustus, true);
        assertTrue(registry.isValidAugustus(newAugustus));
    }

    function test_setAugustus_remove() public {
        registry.setAugustus(augustus, false);
        assertFalse(registry.isValidAugustus(augustus));
    }

    function test_revert_setAugustus_notOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes('ONLY_OWNER'));
        registry.setAugustus(address(0xCAFE), true);
    }

    function test_revert_setAugustus_zeroAddress() public {
        vm.expectRevert(bytes('ZERO_ADDRESS'));
        registry.setAugustus(address(0), true);
    }

    function test_constructorWithZeroAddress() public {
        HydraAugustusRegistry r = new HydraAugustusRegistry(address(0));
        assertFalse(r.isValidAugustus(address(0)));
    }
}
