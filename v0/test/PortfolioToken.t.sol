// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {PortfolioToken} from "../src/PortfolioToken.sol";

contract PortfolioTokenTest is Test {
    PortfolioToken public portfolioToken;
    address public owner;

    function setUp() public {
        owner = msg.sender;
        portfolioToken = new PortfolioToken(owner, "Token", "SYMBOL");
    }

    function testFuzz_onlyOwner(address a, uint256 mintAmount, uint256 burnAmount) public {
        vm.assume(a != msg.sender);
        vm.assume(mintAmount > burnAmount);
        vm.assume(mintAmount > 0);
        vm.assume(burnAmount > 0);

        vm.startPrank(a);
        vm.expectRevert();
        portfolioToken.mint(a, mintAmount);
        vm.expectRevert();
        portfolioToken.burn(a, burnAmount);

        vm.startPrank(owner);
        portfolioToken.mint(a, mintAmount);
        assertEq(portfolioToken.balanceOf(a), mintAmount);
        portfolioToken.burn(a, burnAmount);
        assertEq(portfolioToken.balanceOf(a), mintAmount - burnAmount);
    }
}
