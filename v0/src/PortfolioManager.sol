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

    uint256 public constant ASSET_LIST_MAXIMUM_LENGTH = 20;
    uint256 public constant ASSET_LIST_MINIMUM_LENGTH = 1;
    uint256 internal constant ASSET_WEIGHT_SUM = 100_000;
    uint8 public constant MANGED_PORTFOLIO_MANAGEMENT_FEE = 10;
    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    bytes constant ZERO_BYTES = new bytes(0);

    struct Asset {
        address token; // address(0) = eth
        uint8 targetWeight;
        uint256 amountHeld;
    }

    struct Portfolio {
        address inputToken;
        PortfolioToken portfolioToken;
        PoolId poolId;
        address[] assetAddresses;
        uint8 rebalanceFrequency; // n days
        uint256 rebalancedAt; // timestamp
    }

    struct ManagedPortfolio {
        address inputToken;
        PortfolioToken portfolioToken;
        address manager;
        PoolId poolId;
        address[] currentAssetAddresses;
        address[] targetAssetAddresses;
        uint8 managementFeeBasisPoints;
        uint8 rebalanceFrequency; // n days
        uint256 rebalancedAt; // timestamp
        uint256 updatedAt; // timestamp
    }

    uint256 internal _portfolioId;

    mapping(PoolId poolId => uint256 id) internal poolIdToId;
    mapping(uint256 id => bool isManaged) internal idToIsManaged;

    mapping(uint256 id => Portfolio) internal portfolios;
    mapping(uint256 id => mapping(address => Asset)) internal portfolioAssets;
    mapping(bytes32 hash => uint256 id) internal portfolioHashToId;

    mapping(uint256 id => ManagedPortfolio) internal managedPortfolios;
    mapping(uint256 id => mapping(address => Asset)) internal managedPortfolioCurrentAssets;
    mapping(uint256 id => mapping(address => Asset)) internal managedPortfolioTargetAssets;

    PoolClaimsTest internal claimsRouter;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolSwapTest internal swapRouter;

    error InvalidAssetList();
    error InvalidAssetWeightSum();
    error InvalidPortfolioId();
    error InvalidPortfolioInputToken();
    error InvalidPortfolioManager();
    error InvalidPortfolioRebalanceTimestamp();
    error InvalidPortfolioUpdate();
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

    function _createPool(address inputToken, address portfolioToken) internal returns (PoolId) {
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

        return poolId;
    }

    function _createToken(uint256 id) internal returns (PortfolioToken) {
        string memory name = string.concat("Dortfolio ", Strings.toString(id));
        string memory symbol = string.concat("DORT_", Strings.toString(id));
        return new PortfolioToken(address(this), name, symbol);
    }

    /* 
        Portfolio Management 
    */

    function create(Asset[] calldata assetList, address inputToken, uint8 rebalanceFrequency, bool isManaged) public {
        bytes32 hash = _hash(assetList, rebalanceFrequency);
        uint256 id = _id();
        PortfolioToken portfolioToken = _createToken(id);
        PoolId poolId = _createPool(inputToken, address(portfolioToken));

        poolIdToId[poolId] = id;

        address[] memory assetAddresses = new address[](assetList.length);
        for (uint8 i = 0; i < assetList.length; i++) {
            assetAddresses[i] = assetList[i].token;

            if (isManaged) {
                managedPortfolioCurrentAssets[id][assetList[i].token] = assetList[i];
                managedPortfolioTargetAssets[id][assetList[i].token] = assetList[i];
            } else {
                portfolioAssets[id][assetList[i].token] = assetList[i];
            }
        }

        if (isManaged) {
            managedPortfolios[id] = ManagedPortfolio({
                inputToken: inputToken,
                portfolioToken: portfolioToken,
                manager: msg.sender,
                poolId: poolId,
                currentAssetAddresses: assetAddresses,
                targetAssetAddresses: assetAddresses,
                managementFeeBasisPoints: MANGED_PORTFOLIO_MANAGEMENT_FEE,
                rebalanceFrequency: rebalanceFrequency,
                rebalancedAt: 0,
                updatedAt: 0
            });
        } else {
            portfolios[id] = Portfolio({
                inputToken: inputToken,
                portfolioToken: portfolioToken,
                poolId: poolId,
                assetAddresses: assetAddresses,
                rebalanceFrequency: rebalanceFrequency,
                rebalancedAt: 0
            });

            portfolioHashToId[hash] = id;
        }
    }

    function update(uint256 portfolioId, Asset[] calldata assetList, uint8 rebalanceFrequency)
        public
        onlyManager(portfolioId)
        validate(portfolioId)
    {
        ManagedPortfolio storage mp = managedPortfolios[portfolioId];

        Asset[] memory targetAssetList = new Asset[](mp.targetAssetAddresses.length);
        for (uint8 i = 0; i < mp.targetAssetAddresses.length; i++) {
            address a = mp.targetAssetAddresses[i];
            Asset memory asset = managedPortfolioTargetAssets[portfolioId][a];
            targetAssetList[i] = asset;

            managedPortfolioTargetAssets[portfolioId][a] = Asset({token: a, targetWeight: 0, amountHeld: 0});
        }

        bytes32 hash = _hash(assetList, rebalanceFrequency);
        bytes32 targetHash = _hash(targetAssetList, mp.rebalanceFrequency);
        if (hash == targetHash) {
            revert InvalidPortfolioUpdate();
        }

        address[] memory targetAssetAddresses = new address[](assetList.length);
        for (uint8 i = 0; i < assetList.length; i++) {
            targetAssetAddresses[i] = assetList[i].token;
            managedPortfolioTargetAssets[portfolioId][assetList[i].token] = assetList[i];
        }

        mp.targetAssetAddresses = targetAssetAddresses;
        mp.rebalanceFrequency = rebalanceFrequency;
        rebalance(portfolioId);
    }

    function rebalance(uint256 portfolioId) public {
        if (portfolioId > _portfolioId) {
            revert InvalidPortfolioId();
        }

        bool isManaged = idToIsManaged[portfolioId];
        if (isManaged) {
            ManagedPortfolio storage mp = managedPortfolios[portfolioId];
            if (mp.currentAssetAddresses.length == 0) {
                revert InvalidPortfolioId();
            }
            if (block.timestamp < mp.rebalancedAt + _daysToSeconds(mp.rebalanceFrequency)) {
                revert InvalidPortfolioRebalanceTimestamp();
            }
            // populate unlockCallback
        } else {
            Portfolio storage p = portfolios[portfolioId];
            if (p.assetAddresses.length == 0) {
                revert InvalidPortfolioId();
            }
            if (block.timestamp < p.rebalancedAt + _daysToSeconds(p.rebalanceFrequency)) {
                revert InvalidPortfolioRebalanceTimestamp();
            }
            // populate unlockCallback
        }

        // poolManager.unlock();

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

    function mint(uint256 portfolioId, uint256 amount) public validate(portfolioId) {
        // portfolio buys tokens using the deposited amount
        // revert if no EIP-2612 permit to spend token amount
        rebalance(portfolioId);
    }

    function burn(uint256 portfolioId, uint256 amount) public validate(portfolioId) {
        // revert if no EIP-2612 permit to spend token amount
        // portfolio buys tokens using the deposited amount
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

    function _getFee(PoolId poolId) internal view returns (uint24) {
        // if pt price < nav/shares --> discount buys
        // if pt price > nav/shares --> discount sells

        // compare [nav / totalshares] to tick-->price
        return 1;
    }

    function _nav(uint256 portfolioId) internal view returns (uint256) {
        return 1;
    }

    function _daysToSeconds(uint8 d) internal pure returns (uint256) {
        return uint256(d) * 60 * 60 * 24;
    }

    function _hash(Asset[] memory assetList, uint8 rebalanceFrequency) internal pure returns (bytes32) {
        if (assetList.length > ASSET_LIST_MAXIMUM_LENGTH || assetList.length < ASSET_LIST_MINIMUM_LENGTH) {
            revert InvalidAssetList();
        }

        uint256 totalWeight = assetList[0].targetWeight;

        for (uint256 i = 1; i < assetList.length; i++) {
            // addresses must be sorted and unique
            if (assetList[i - 1].token >= assetList[i].token) {
                revert InvalidAssetList();
            }
            totalWeight += assetList[i].targetWeight;
        }

        // asset weights must total 100%
        if (totalWeight != ASSET_WEIGHT_SUM) {
            revert InvalidAssetWeightSum();
        }

        return keccak256(abi.encode(assetList, rebalanceFrequency));
    }

    modifier onlyManager(uint256 portfolioId) {
        if (msg.sender != managedPortfolios[portfolioId].manager) {
            revert InvalidPortfolioManager();
        }
        _;
    }

    modifier validate(uint256 portfolioId) {
        if (portfolioId > _portfolioId) {
            revert InvalidPortfolioId();
        }

        bool isManaged = idToIsManaged[portfolioId];

        if (isManaged) {
            if (managedPortfolios[portfolioId].currentAssetAddresses.length == 0) {
                revert InvalidPortfolioId();
            }
        } else {
            if (portfolios[portfolioId].assetAddresses.length == 0) {
                revert InvalidPortfolioId();
            }
        }

        _;
    }
}
