// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary, PoolKey} from "v4-core/types/PoolId.sol";

import {PoolClaimsTest} from "v4-core/test/PoolClaimsTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {BaseHook, Hooks, IHooks, IPoolManager} from "v4-periphery/BaseHook.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {PortfolioToken, ERC20} from "./PortfolioToken.sol";

contract PortfolioManager is BaseHook {
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;

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

    uint256 ASSET_LIST_MAXIMUM_LENGTH = 20;
    uint256 ASSET_LIST_MINIMUM_LENGTH = 1;
    uint256 ASSET_WEIGHT_SUM = 100_000;
    uint8 MANGED_PORTFOLIO_MANAGEMENT_FEE = 10;
    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    bytes constant ZERO_BYTES = new bytes(0);

    uint256 internal _portfolioId;

    mapping(bytes32 hash => uint256 id) internal hashToId;
    mapping(PoolId poolId => uint256 id) internal poolIdToId;
    mapping(uint256 id => bool isManaged) internal idToIsManaged;

    mapping(uint256 id => Portfolio) internal portfolios;
    mapping(uint256 id => ManagedPortfolio) internal managedPortfolios;

    PoolClaimsTest internal claimsRouter;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolSwapTest internal swapRouter;

    error InvalidAssetList();
    error InvalidAssetWeightSum();
    error InvalidPortfolioId();
    error InvalidPortfolioInputToken();
    error InvalidPortfolioManager();
    error InvalidPortfolioRebalanceTimestamp();
    error MustUseDynamicFee();

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
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) {
            revert MustUseDynamicFee();
        }
        return this.beforeInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // discount fees for swaps pushing portfolio token price closer to NAV
        uint24 fee = _getFee(key.toId());

        // Update swapFee in the manager
        poolManager.updateDynamicLPFee(key, fee);
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

    function initPool(
        Currency _currency0,
        Currency _currency1,
        IHooks hooks,
        uint24 fee,
        uint160 sqrtPriceX96,
        bytes memory initData
    ) internal returns (PoolKey memory _key, PoolId id) {
        _key = PoolKey(_currency0, _currency1, fee, fee.isDynamicFee() ? int24(60) : int24(fee / 100 * 2), hooks);
        id = _key.toId();
        poolManager.initialize(_key, sqrtPriceX96, initData);
    }

    // function initPool(
    //     Currency _currency0,
    //     Currency _currency1,
    //     IHooks hooks,
    //     uint24 fee,
    //     int24 tickSpacing,
    //     uint160 sqrtPriceX96,
    //     bytes memory initData
    // ) internal returns (PoolKey memory _key, PoolId id) {
    //     _key = PoolKey(_currency0, _currency1, fee, tickSpacing, hooks);
    //     id = _key.toId();
    //     poolManager.initialize(_key, sqrtPriceX96, initData);
    // }

    /* 
        Portfolio Management 
    */

    function create(Asset[] memory assets, address inputToken, uint8 rebalanceFrequency, bool isManaged) public {
        bytes32 hash = _hash(assets, rebalanceFrequency);

        uint256 id = _id();
        string memory name = string.concat("Dortfolio ", Strings.toString(id));
        string memory symbol = string.concat("DORT_", Strings.toString(id));

        PortfolioToken pt = new PortfolioToken(address(this), name, symbol);
        address portfolioToken = address(pt);

        Currency currency0;
        Currency currency1;
        if (inputToken < portfolioToken) {
            currency0 = Currency.wrap(inputToken);
            currency1 = Currency.wrap(portfolioToken);
        } else if (inputToken > portfolioToken) {
            currency0 = Currency.wrap(portfolioToken);
            currency1 = Currency.wrap(inputToken);
        } else {
            revert InvalidPortfolioInputToken();
        }

        ( /*PoolKey memory poolKey*/ , PoolId poolId) = initPool(
            currency0,
            currency1,
            IHooks(address(this)),
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // Set the `DYNAMIC_FEE_FLAG` in place of specifying a fixed fee
            SQRT_PRICE_1_1,
            ZERO_BYTES
        );

        hashToId[hash] = id;
        poolIdToId[poolId] = id;

        if (isManaged) {
            managedPortfolios[id] = ManagedPortfolio({
                inputToken: inputToken,
                portfolioToken: pt,
                manager: msg.sender,
                poolId: poolId,
                currentAssets: assets,
                targetAssets: assets,
                managementFeeBasisPoints: MANGED_PORTFOLIO_MANAGEMENT_FEE,
                rebalanceFrequency: rebalanceFrequency,
                rebalancedAt: 0,
                updatedAt: 0
            });
        } else {
            portfolios[id] = Portfolio({
                inputToken: inputToken,
                portfolioToken: pt,
                poolId: poolId,
                assets: assets,
                rebalanceFrequency: rebalanceFrequency,
                rebalancedAt: 0
            });
        }
    }

    function update(uint256 portfolioId, Asset[] memory assets, uint8 rebalanceFrequency)
        public
        onlyManager(portfolioId)
    {
        bytes32 hash = _hash(assets, rebalanceFrequency);
        ManagedPortfolio memory mp = managedPortfolios[portfolioId];
        bytes32 targetHash = _hash(mp.targetAssets, mp.rebalanceFrequency);

        if (hash != targetHash) {
            mp.targetAssets = assets;
            mp.rebalanceFrequency = rebalanceFrequency;
        }

        rebalance(portfolioId);
    }

    function rebalance(uint256 portfolioId) public {
        bool isManaged = idToIsManaged[portfolioId];

        if (isManaged) {
            ManagedPortfolio memory mp = managedPortfolios[portfolioId];
            if (mp.currentAssets.length == 0) {
                revert InvalidPortfolioId();
            }
            if (block.timestamp < mp.rebalancedAt + _daysToSeconds(mp.rebalanceFrequency)) {
                revert InvalidPortfolioRebalanceTimestamp();
            }
            // poolManager.unlock();
        } else {
            Portfolio memory p = portfolios[portfolioId];
            if (p.assets.length == 0) {
                revert InvalidPortfolioId();
            }
            if (block.timestamp < p.rebalancedAt + _daysToSeconds(p.rebalanceFrequency)) {
                revert InvalidPortfolioRebalanceTimestamp();
            }
            // poolManager.unlock();
        }

        /*
        struct CallbackData {
            address sender;
            TestSettings testSettings;
            PoolKey key;
            IPoolManager.SwapParams params;
            bytes hookData;
        }
        struct TestSettings {
            bool takeClaims;
            bool settleUsingBurn;
        }
        */
    }

    function mint(uint256 portfolioId, uint256 amount) public {
        if (portfolioId > _portfolioId) {
            revert InvalidPortfolioId();
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
            revert InvalidPortfolioId();
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

    function _id() internal returns (uint256) {
        return ++_portfolioId;
    }

    function _hash(Asset[] memory assets, uint8 rebalanceFrequency) internal view returns (bytes32) {
        if (assets.length > ASSET_LIST_MAXIMUM_LENGTH || assets.length < ASSET_LIST_MINIMUM_LENGTH) {
            revert InvalidAssetList();
        }

        uint256 totalWeight = assets[0].targetWeight;

        for (uint256 i = 1; i < assets.length; i++) {
            // addresses must be sorted and unique
            if (assets[i - 1].token >= assets[i].token) {
                revert InvalidAssetList();
            }
            totalWeight += assets[i].targetWeight;
        }

        // asset weights must total 100%
        if (totalWeight != ASSET_WEIGHT_SUM) {
            revert InvalidAssetWeightSum();
        }

        return keccak256(abi.encode(assets, rebalanceFrequency));
    }

    function _getFee(PoolId poolId) internal returns (uint24) {
        return 1;
    }

    function _nav(uint256 portfolioId) internal view returns (uint256) {
        return 1;
    }

    function _daysToSeconds(uint8 d) internal pure returns (uint256) {
        return uint256(d) * 60 * 60 * 24;
    }

    modifier onlyManager(uint256 portfolioId) {
        if (msg.sender != managedPortfolios[portfolioId].manager) {
            revert InvalidPortfolioManager();
        }
        _;
    }
}
