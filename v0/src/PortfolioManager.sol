// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {PortfolioToken} from "./PortfolioToken.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolClaimsTest} from "v4-core/test/PoolClaimsTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

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

    // beforeSwap
    // --> discount fees for swaps pushing portfolio token price closer to NAV

    // afterSwap, afterAddLiquidity, afterRemoveLiquidity
    // --> rebalance

    function createPortfolio(Asset[] memory assets) public {
        // deploy ERC20
        // create LP
        // assets must be ordered by weight; large to small
        // assets weights must total 100
    }
    function createManagedPortfolio(Asset[] memory assets) public {
        // deploy ERC20
        // create LP
        // assets weights must total 100
    }

    function updateManagedPortfolio(uint256 portfolioId, Asset[] memory assets) public {
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

        rebalancePortfolio(portfolioId);
    }

    function rebalancePortfolio(uint256 portfolioId) public {
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
        rebalancePortfolio(portfolioId);
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
        rebalancePortfolio(portfolioId);
    }

    function getPortfolio(uint256 id) public view returns (Portfolio memory) {
        return portfolios[id];
    }

    function getManagedPortfolio(uint256 id) public view returns (ManagedPortfolio memory) {
        return managedPortfolios[id];
    }

    function _getHash(Asset[] memory assets, uint256 rebalanceFrequency) internal returns (bytes32) {}

    function _getPortfolioId() internal returns (uint256) {
        return ++_portfolioId;
    }

    function _getPortfolioNav(uint256 portfolioId) internal view returns (uint256) {
        return 1;
    }
}
