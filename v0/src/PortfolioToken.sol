// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {Owned} from "solmate/auth/Owned.sol";

contract PortfolioToken is ERC20, Owned {
    constructor(address _owner, string memory _name, string memory _symbol) ERC20(_name, _symbol, 18) Owned(_owner) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}
