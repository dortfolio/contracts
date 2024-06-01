// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {TokenDeployer} from "../src/TokenDeployer.sol";
import {PortfolioToken} from "../src/PortfolioToken.sol";

contract TokenDeployerTest is Test {
    TokenDeployer public tokenDeployer;

    function setUp() public {
        tokenDeployer = new TokenDeployer();
    }

    function test_deploy() public {
        PortfolioToken token = tokenDeployer.deploy("Name", "SYMBOL");
        assertEq(address(tokenDeployer), token.owner());
        assertEq(tokenDeployer.getToken(address(token)).name(), token.name());
        assertEq(tokenDeployer.getToken(address(token)).symbol(), token.symbol());

        PortfolioToken token2 = tokenDeployer.deploy("Name2", "SYMBOL2");
        assertEq(address(tokenDeployer), token2.owner());
        assertEq(tokenDeployer.getToken(address(token2)).name(), token2.name());
        assertEq(tokenDeployer.getToken(address(token2)).symbol(), token2.symbol());
    }
}
