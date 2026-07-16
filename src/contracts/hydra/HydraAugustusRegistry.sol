// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IParaSwapAugustusRegistry} from '../dependencies/paraswap/IParaSwapAugustusRegistry.sol';

/**
 * @title HydraAugustusRegistry
 * @notice Minimal registry that tracks valid HydraAugustus instances, implementing the
 *         IParaSwapAugustusRegistry interface required by the Aave ParaSwap adapter stack.
 */
contract HydraAugustusRegistry is IParaSwapAugustusRegistry {
    address public owner;
    mapping(address => bool) internal _validAugustus;

    modifier onlyOwner() {
        require(msg.sender == owner, 'ONLY_OWNER');
        _;
    }

    constructor(address initialAugustus) {
        owner = msg.sender;
        if (initialAugustus != address(0)) {
            _validAugustus[initialAugustus] = true;
        }
    }

    function isValidAugustus(address augustus) external view override returns (bool) {
        return _validAugustus[augustus];
    }

    /**
     * @notice Add or remove an Augustus address from the valid set.
     * @param augustus The HydraAugustus contract address.
     * @param valid   Whether the address should be considered valid.
     */
    function setAugustus(address augustus, bool valid) external onlyOwner {
        require(augustus != address(0), 'ZERO_ADDRESS');
        _validAugustus[augustus] = valid;
    }

    /**
     * @notice Transfer ownership of this registry to a new address.
     * @param newOwner The address of the new owner.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), 'ZERO_ADDRESS');
        owner = newOwner;
    }
}
