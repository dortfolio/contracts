// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {
    Hooks,
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
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                    | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            )
        );

        deployFreshManagerAndRouters();
        deployCodeTo(
            "PortfolioManagerHarness", abi.encode(manager, claimsRouter, modifyLiquidityRouter, swapRouter), hookAddress
        );

        pm = PortfolioManagerHarness(hookAddress);
    }

    function test_Increment() public {
        assertEq(pm.exposed_id(), 1);
        assertEq(pm.exposed_id(), 2);
        assertEq(pm.exposed_id(), 3);

        // uint256 id1 = pm.getId();
        // assertEq(pm.id(), 1);
        // assertEq(pm.id(), id1);

        // uint256 id2 = pm.getId();
        // assertEq(pm.id(), 2);
        // assertEq(pm.id(), id2);
    }
}
