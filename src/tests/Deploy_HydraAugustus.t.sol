// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import 'forge-std/Test.sol';
import {DeployHydraAugustus} from 'src/script/Deploy_HydraAugustus.s.sol';
import {HydraAugustus} from 'src/contracts/hydra/HydraAugustus.sol';
import {HydraAugustusRegistry} from 'src/contracts/hydra/HydraAugustusRegistry.sol';

contract DeployHydraAugustusTest is Test {
    DeployHydraAugustus internal deployer;

    address internal constant DISPATCH = address(0x0401);
    uint32 internal constant PRIME_ID = 43;
    uint32 internal constant HOLLAR_ID = 222;

    address internal gov;
    address internal prime;
    address internal hollar;

    function setUp() public {
        deployer = new DeployHydraAugustus();
        gov = makeAddr('governance');
        prime = makeAddr('prime');
        hollar = makeAddr('hollar');
    }

    function test_deployAndConfigure_registersAssetIdsAndHandsOver() public {
        (HydraAugustus augustus, HydraAugustusRegistry registry) =
            deployer.deployAndConfigure(DISPATCH, gov, prime, hollar, PRIME_ID, HOLLAR_ID);

        // dispatch wired
        assertEq(augustus.DISPATCH(), DISPATCH, 'dispatch');

        // asset ids registered while the deployer was the transient owner
        assertEq(augustus.assetId(prime), PRIME_ID, 'prime id');
        assertEq(augustus.assetId(hollar), HOLLAR_ID, 'hollar id');

        // ownership handed to governance on both contracts
        assertEq(augustus.owner(), gov, 'augustus owner');
        assertEq(registry.owner(), gov, 'registry owner');

        // instance registered as a valid Augustus
        assertTrue(registry.isValidAugustus(address(augustus)), 'registered');
    }

    /// @notice After handover, governance (not the deployer) controls configuration.
    function test_deployAndConfigure_governanceControlsAfterHandover() public {
        (HydraAugustus augustus, ) =
            deployer.deployAndConfigure(DISPATCH, gov, prime, hollar, PRIME_ID, HOLLAR_ID);

        // the deployer/test can no longer configure
        vm.expectRevert(bytes('ONLY_OWNER'));
        augustus.setAssetId(prime, 999);

        // governance can
        vm.prank(gov);
        augustus.setAssetId(prime, 999);
        assertEq(augustus.assetId(prime), 999);
    }
}
