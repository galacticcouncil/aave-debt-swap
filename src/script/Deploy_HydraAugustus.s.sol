// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Script} from 'forge-std/Script.sol';
import {HydraAugustus} from 'src/contracts/hydra/HydraAugustus.sol';
import {HydraAugustusRegistry} from 'src/contracts/hydra/HydraAugustusRegistry.sol';

/**
 * @title Deploy_HydraAugustus
 * @notice Deploys HydraAugustus on Hydration, registers the PRIME/HOLLAR asset ids for the
 *         empty-route (keeper) path, registers the instance in a HydraAugustusRegistry, and
 *         hands ownership of both to governance.
 *
 * @dev Hydration is not an aave-address-book chain, so the addresses below are PLACEHOLDERS —
 *      fill them in before broadcasting:
 *
 *        forge script src/script/Deploy_HydraAugustus.s.sol:DeployHydraAugustus \
 *          --rpc-url <HYDRATION_EVM_RPC> --broadcast --slow
 *
 *      OFF-CHAIN PREREQUISITES (substrate governance — NOT performed by this script):
 *        1. Whitelist the broadcasting EOA as a contract deployer on Hydration
 *           (`evmAccounts.addContractDeployer`) — see scripts/test-hydra-e2e.ts.
 *        2. Set the PRIME⇄HOLLAR route on the router pallet
 *           (`pallet_route_executor::set_route`, the route Ben identifies). Without it the
 *           router falls back to a default pool that cannot service the pair and swaps revert.
 */
contract DeployHydraAugustus is Script {
    // ─── FILL THESE IN before broadcasting ────────────────────────────────
    /// @dev Frontier dispatch precompile — fixed on Hydration.
    address internal constant DISPATCH = 0x0000000000000000000000000000000000000401;

    /// @dev Governance owner for the asset-id map + registry (the Hydration governance
    ///      account's mapped EVM address / a multisig). PLACEHOLDER.
    address internal constant GOVERNANCE = 0x000000000000000000000000000000000000dEaD;

    /// @dev PRIME / HOLLAR token addresses on Hydration. PLACEHOLDERS.
    address internal constant PRIME = address(0);
    address internal constant HOLLAR = address(0);

    /// @dev Substrate asset ids (from the plan — confirm against runtime metadata).
    uint32 internal constant PRIME_ASSET_ID = 43;
    uint32 internal constant HOLLAR_ASSET_ID = 222;
    // ──────────────────────────────────────────────────────────────────────

    function run() external {
        require(PRIME != address(0) && HOLLAR != address(0), 'FILL_TOKEN_ADDRESSES');
        require(GOVERNANCE != address(0), 'FILL_GOVERNANCE');

        vm.startBroadcast();
        deployAndConfigure(DISPATCH, GOVERNANCE, PRIME, HOLLAR, PRIME_ASSET_ID, HOLLAR_ASSET_ID);
        vm.stopBroadcast();
    }

    /**
     * @notice Deploy HydraAugustus + registry, register asset ids, hand ownership to `governance`.
     * @dev Public (non-broadcast) so tests exercise the exact sequence. The caller (the
     *      broadcasting EOA in `run`, or the test contract) is the transient owner while asset
     *      ids are set, then ownership moves to `governance`. Order matters: asset ids MUST be
     *      set before the handover, or the deployer loses the right to set them.
     */
    function deployAndConfigure(
        address dispatch,
        address governance,
        address prime,
        address hollar,
        uint32 primeId,
        uint32 hollarId
    ) public returns (HydraAugustus augustus, HydraAugustusRegistry registry) {
        // 1. Deploy the swap engine (deployer is the transient owner).
        augustus = new HydraAugustus(dispatch);

        // 2. Register PRIME/HOLLAR for the empty-route (keeper) path.
        augustus.setAssetId(prime, primeId);
        augustus.setAssetId(hollar, hollarId);

        // 3. Register the instance in an Augustus registry (used by this repo's debt-swap
        //    adapters; Propeller points its ISwapper directly at `augustus` and skips this).
        registry = new HydraAugustusRegistry(address(augustus));

        // 4. Hand both over to governance — owner must be governance, not a hot key.
        augustus.transferOwnership(governance);
        registry.transferOwnership(governance);
    }
}
