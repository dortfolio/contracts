// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {PortfolioToken} from "./PortfolioToken.sol";

contract TokenDeployer {
    mapping(address => PortfolioToken) public tokens;

    function deploy(string memory name, string memory symbol) public returns (PortfolioToken) {
        PortfolioToken token = new PortfolioToken(address(this), name, symbol);
        tokens[address(token)] = token;
        return token;
    }

    function getToken(address token) public view returns (PortfolioToken) {
        return tokens[token];
    }
}
