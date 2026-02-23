// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IParaSwapAugustusRegistry} from '../dependencies/paraswap/IParaSwapAugustusRegistry.sol';

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

    function setAugustus(address augustus, bool valid) external onlyOwner {
        require(augustus != address(0), 'ZERO_ADDRESS');
        _validAugustus[augustus] = valid;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), 'ZERO_ADDRESS');
        owner = newOwner;
    }
}
