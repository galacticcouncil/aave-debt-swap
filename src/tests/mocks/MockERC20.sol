// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {ERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/ERC20.sol';

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_, uint8 /*decimals_*/) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
