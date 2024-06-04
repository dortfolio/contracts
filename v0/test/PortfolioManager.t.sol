// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {
    IPoolManager,
    PoolClaimsTest,
    PoolModifyLiquidityTest,
    PoolSwapTest,
    PortfolioManager
} from "../src/PortfolioManager.sol";

contract PortfolioManagerHarness is PortfolioManager {
    constructor(
        IPoolManager manager,
        PoolClaimsTest claimsRouter,
        PoolModifyLiquidityTest modifyLiquidityRouter,
        PoolSwapTest swapRouter
    ) PortfolioManager(manager, claimsRouter, modifyLiquidityRouter, swapRouter) {}

    function exposed_id() external returns (uint256) {
        return _id();
    }
}

contract PortfolioManagerTest is Test, Deployers {
    PortfolioManagerHarness public pm;

    function setUp() public {
        deployFreshManagerAndRouters();
        pm = new PortfolioManagerHarness(manager, claimsRouter, modifyLiquidityRouter, swapRouter);
    }

    function test_Increment() public {
        assertEq(pm.exposed_id(), 1);

        // uint256 id1 = pm.getId();
        // assertEq(pm.id(), 1);
        // assertEq(pm.id(), id1);

        // uint256 id2 = pm.getId();
        // assertEq(pm.id(), 2);
        // assertEq(pm.id(), id2);
    }
}
