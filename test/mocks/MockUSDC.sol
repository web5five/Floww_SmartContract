// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Floww Sepolia Mock USDC", "fUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function faucet(address account, uint256 amount) external {
        _mint(account, amount);
    }
}
