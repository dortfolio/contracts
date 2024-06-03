// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary, PoolKey} from "v4-core/types/PoolId.sol";
import {PoolClaimsTest} from "v4-core/test/PoolClaimsTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {BaseHook, Hooks, IHooks, IPoolManager} from "v4-periphery/BaseHook.sol";
import {PortfolioToken, ERC20} from "./PortfolioToken.sol";

contract PortfolioManager is BaseHook {
    struct Asset {
        address token; // address(0) = eth
        uint8 targetWeight;
        uint256 amountHeld;
    }

    struct Portfolio {
        address inputToken;
        PortfolioToken portfolioToken;
        PoolId poolId;
        Asset[] assets;
        uint8 rebalanceFrequency; // n days
        uint256 rebalancedAt; // timestamp
    }

    struct ManagedPortfolio {
        address inputToken;
        PortfolioToken portfolioToken;
        address manager;
        PoolId poolId;
        Asset[] currentAssets;
        Asset[] targetAssets;
        uint8 managementFeeBasisPoints;
        uint8 rebalanceFrequency; // n days
        uint256 rebalancedAt; // timestamp
        uint256 updatedAt; // timestamp
    }

    uint256 internal _portfolioId;
    mapping(bytes32 hash => uint256 id) internal hashToId;
    mapping(uint256 id => bool isManaged) internal idToIsManaged;

    mapping(uint256 id => Portfolio) internal portfolios;
    mapping(uint256 id => ManagedPortfolio) internal managedPortfolios;

    PoolClaimsTest internal claimsRouter;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolSwapTest internal swapRouter;

    uint256 ASSET_WEIGHT_SUM = 100_000;

    error InvalidAssetWeightSum();
    error InvalidPortfolioID();

    constructor(
        IPoolManager _poolManager,
        PoolClaimsTest _claimsRouter,
        PoolModifyLiquidityTest _modifyLiquidityRouter,
        PoolSwapTest _swapRouter
    ) BaseHook(_poolManager) {
        claimsRouter = _claimsRouter;
        modifyLiquidityRouter = _modifyLiquidityRouter;
        swapRouter = _swapRouter;
    }

    /*
        UniswapV4 Hook
    */

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // discount fees for swaps pushing portfolio token price closer to NAV
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, int128) {
        // rebalance
        return (IHooks.afterSwap.selector, 0);
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        // rebalance
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        // rebalance
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /* 
        Portfolio Management 
    */

    function create(Asset[] memory assets, address inputToken, bool isManaged) public {
        // deploy ERC20
        // create LP
        // hash --> assets must be ordered by weight; large to small
        // assets weights must total 100
    }

    function update(uint256 portfolioId, Asset[] memory assets) public {
        uint256 totalWeight;

        for (uint256 i; i < assets.length; i++) {
            // Asset memory a = assets[i];
            // a.targetWeight
            totalWeight += assets[i].targetWeight;
        }

        if (totalWeight != ASSET_WEIGHT_SUM) {
            // make 100_000 a constant
            revert InvalidAssetWeightSum();
        }

        rebalance(portfolioId);
    }

    function rebalance(uint256 portfolioId) public {
        // do not rebalance if this was triggered by a recursive portfolio
        bool isManaged = idToIsManaged[portfolioId];

        if (isManaged) {
            ManagedPortfolio storage p = managedPortfolios[portfolioId];
        } else {
            Portfolio storage p = portfolios[portfolioId];
        }
    }

    function mint(uint256 portfolioId, uint256 amount) public {
        if (portfolioId > _portfolioId) {
            revert InvalidPortfolioID();
        }
        bool isManaged = idToIsManaged[portfolioId];

        // portfolio buys tokens using the deposited amount
        if (isManaged) {
            //
        }
        rebalance(portfolioId);
    }

    function burn(uint256 portfolioId, uint256 amount) public {
        // portfolio sells tokens using the deposited amount
        if (portfolioId > _portfolioId) {
            revert InvalidPortfolioID();
        }
        bool isManaged = idToIsManaged[portfolioId];

        // revert if no EIP-2612 permit to spend token amount
        // portfolio buys tokens using the deposited amount
        if (isManaged) {
            //
        }
        rebalance(portfolioId);
    }

    function get(uint256 id) public view returns (Portfolio memory) {
        return portfolios[id];
    }

    function getManaged(uint256 id) public view returns (ManagedPortfolio memory) {
        return managedPortfolios[id];
    }

    function _hash(Asset[] memory assets, uint256 rebalanceFrequency) internal returns (bytes32) {}

    function _id() internal returns (uint256) {
        return ++_portfolioId;
    }

    function _nav(uint256 portfolioId) internal view returns (uint256) {
        return 1;
    }
}
