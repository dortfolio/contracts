// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary, PoolKey} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

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
    using StateLibrary for IPoolManager;

    uint256 public constant ASSET_LIST_MAXIMUM_LENGTH = 20;
    uint256 public constant ASSET_LIST_MINIMUM_LENGTH = 2;
    uint256 internal constant ASSET_WEIGHT_SUM = 100_000;
    uint8 public constant MANGED_PORTFOLIO_MANAGEMENT_FEE = 10;
    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    bytes constant ZERO_BYTES = new bytes(0);

    struct Asset {
        address token; // address(0) = eth
        uint8 decimals;
        uint24 targetWeight;
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

    mapping(PoolId poolId => uint256 id) public poolIdToId;
    mapping(uint256 id => bool isManaged) public idToIsManaged;

    mapping(uint256 id => Portfolio) public portfolios;
    mapping(uint256 id => mapping(address => Asset)) public portfolioAssets;
    mapping(bytes32 hash => uint256 id) public portfolioHashToId;

    mapping(uint256 id => ManagedPortfolio) public managedPortfolios;
    mapping(uint256 id => mapping(address => Asset)) public managedPortfolioCurrentAssets;
    mapping(uint256 id => mapping(address => Asset)) public managedPortfolioTargetAssets;

    mapping(bytes32 pair => PoolKey poolKey) public _pairToPoolKey; // Hackathon helper

    uint256 internal _portfolioId;

    PoolClaimsTest internal claimsRouter;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolSwapTest internal swapRouter;

    error InvalidAssetList();
    error InvalidAssetWeightSum();
    error InvalidPortfolioId();
    error InvalidPortfolioInputToken();
    error InvalidPortfolioManager();
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
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, _fee(poolIdToId[key.toId()]));
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4, int128)
    {
        rebalance(poolIdToId[key.toId()]);
        return (IHooks.afterSwap.selector, 0);
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        rebalance(poolIdToId[key.toId()]);
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        rebalance(poolIdToId[key.toId()]);
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
        // Set gas value to enable testnet deployment
        // https://discord.com/channels/1202009457014349844/1247610334999482571
        poolManager.initialize{gas: 800_000}(_key, sqrtPriceX96, initData);
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

    function _createLiquidityPool(address inputToken, address portfolioToken) internal returns (PoolId) {
        Currency currency0;
        Currency currency1;
        if (inputToken < portfolioToken) {
            currency0 = Currency.wrap(inputToken);
            currency1 = Currency.wrap(portfolioToken);
        } else {
            currency0 = Currency.wrap(portfolioToken);
            currency1 = Currency.wrap(inputToken);
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

    function _createPortfolioToken(uint256 id) internal returns (PortfolioToken) {
        string memory name = string.concat("Dortfolio ", Strings.toString(id));
        string memory symbol = string.concat("DORT_", Strings.toString(id));
        return new PortfolioToken(address(this), name, symbol);
    }

    /* 
        Portfolio Management 
    */

    function mint(uint256 portfolioId, uint256 inputTokenAmount) public payable validateId(portfolioId) {
        // portfolio buys tokens using the deposited amount
        // portfolio transfers erc20 portfolio tokens to msg.sender
        // revert if no EIP-2612 permit to spend token amount
        rebalance(portfolioId);
    }

    function burn(uint256 portfolioId, uint256 portfolioTokenAmount) public validateId(portfolioId) {
        // revert if no EIP-2612 permit to spend token amount
        // portfolio burns specified amount of portfolio tokens
        // portfolio sells assets for inputToken
        // portfolio transfers inputToken to msg.sender
        rebalance(portfolioId);
    }

    function create(Asset[] calldata assetList, address inputToken, uint8 rebalanceFrequency, bool isManaged)
        public
        returns (uint256)
    {
        // validate assetList
        bytes32 hash = _hash(assetList, inputToken, rebalanceFrequency);

        // deploy new token and pool
        uint256 portfolioId = _id();
        PortfolioToken portfolioToken = _createPortfolioToken(portfolioId);
        PoolId poolId = _createLiquidityPool(inputToken, address(portfolioToken));

        // state update
        poolIdToId[poolId] = portfolioId;

        // construct assetAddresses
        address[] memory assetAddresses = new address[](assetList.length);
        for (uint8 i = 0; i < assetList.length; i++) {
            assetAddresses[i] = assetList[i].token;
            // state updates
            if (isManaged) {
                managedPortfolioCurrentAssets[portfolioId][assetList[i].token] = assetList[i];
                managedPortfolioTargetAssets[portfolioId][assetList[i].token] = assetList[i];
            } else {
                portfolioAssets[portfolioId][assetList[i].token] = assetList[i];
            }
        }

        // state updates
        if (isManaged) {
            managedPortfolios[portfolioId] = ManagedPortfolio({
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
            portfolios[portfolioId] = Portfolio({
                inputToken: inputToken,
                portfolioToken: portfolioToken,
                poolId: poolId,
                assetAddresses: assetAddresses,
                rebalanceFrequency: rebalanceFrequency,
                rebalancedAt: 0
            });

            portfolioHashToId[hash] = portfolioId;
        }

        rebalance(portfolioId);
        return portfolioId;
    }

    function update(uint256 portfolioId, Asset[] calldata assetList, uint8 rebalanceFrequency)
        public
        onlyManager(portfolioId)
        validateId(portfolioId)
    {
        ManagedPortfolio storage mp = managedPortfolios[portfolioId];

        // construct targetAssetList
        Asset[] memory targetAssetList = new Asset[](mp.targetAssetAddresses.length);
        for (uint8 i = 0; i < mp.targetAssetAddresses.length; i++) {
            address a = mp.targetAssetAddresses[i];
            Asset memory asset = managedPortfolioTargetAssets[portfolioId][a];
            targetAssetList[i] = asset;

            // state update: reset old targetAsset
            managedPortfolioTargetAssets[portfolioId][a] =
                Asset({token: a, decimals: 0, targetWeight: 0, amountHeld: 0});
        }

        // validate new assetList and ensure it is different from targetAssetList
        bytes32 hash = _hash(assetList, mp.inputToken, rebalanceFrequency);
        bytes32 targetHash = _hash(targetAssetList, mp.inputToken, mp.rebalanceFrequency);
        if (hash == targetHash) {
            revert InvalidPortfolioUpdate();
        }

        address[] memory targetAssetAddresses = new address[](assetList.length);
        for (uint8 i = 0; i < assetList.length; i++) {
            targetAssetAddresses[i] = assetList[i].token;
            // state update: set new targetAsset
            managedPortfolioTargetAssets[portfolioId][assetList[i].token] = assetList[i];
        }

        // state updates
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
            if (block.timestamp < mp.rebalancedAt + (mp.rebalanceFrequency * 1 days)) {
                return;
            }
            // populate unlockCallback
        } else {
            Portfolio storage p = portfolios[portfolioId];
            if (p.assetAddresses.length == 0) {
                revert InvalidPortfolioId();
            }
            if (block.timestamp < p.rebalancedAt + (p.rebalanceFrequency * 1 days)) {
                return;
            }
            // populate unlockCallback
        }

        // https://docs.uniswap.org/contracts/v4/concepts/lock-mechanism
        // lock was renamed to unlock --> https://github.com/Uniswap/v4-core/pull/508
        poolManager.unlock(abi.encodeCall(this._rebalance, (isManaged, msg.sender)));

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

    function _rebalance(bool isManaged, address sender) external selfOnly {}

    //
    //
    // NAV TEST
    function navTest(uint256 portfolioId, bool isManaged) public view returns (uint256) {
        Asset[] memory assetList;
        PoolKey[] memory assetPoolKeys;
        if (isManaged) {
            ManagedPortfolio memory portfolio = managedPortfolios[portfolioId];
            address[] memory assetAddresses = portfolio.currentAssetAddresses;
            assetList = new Asset[](assetAddresses.length);
            assetPoolKeys = new PoolKey[](assetAddresses.length);

            for (uint8 i = 0; i < assetAddresses.length; i++) {
                assetList[i] = managedPortfolioCurrentAssets[portfolioId][assetAddresses[i]];
                bytes32 hash = _hashPair(portfolio.inputToken, assetList[i].token);
                assetPoolKeys[i] = _pairToPoolKey[hash];
            }
        } else {
            Portfolio memory portfolio = portfolios[portfolioId];
            address[] memory assetAddresses = portfolio.assetAddresses;
            assetList = new Asset[](assetAddresses.length);
            assetPoolKeys = new PoolKey[](assetAddresses.length);

            for (uint8 i = 0; i < assetAddresses.length; i++) {
                assetList[i] = portfolioAssets[portfolioId][assetAddresses[i]];
                bytes32 hash = _hashPair(portfolio.inputToken, assetList[i].token);
                assetPoolKeys[i] = _pairToPoolKey[hash];
            }
        }

        uint256 navSqrtPriceX96 = 0;
        for (uint8 i = 0; i < assetList.length; i++) {
            uint256 amount = assetList[i].amountHeld * 10 ** assetList[i].decimals;
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(assetPoolKeys[i].toId());
            navSqrtPriceX96 += (amount * sqrtPriceX96);
        }
        return navSqrtPriceX96;
    }
    // NAV TEST
    //
    //

    function nav(uint256 portfolioId, bool isManaged) public returns (uint256) {
        Asset[] memory assetList;
        PoolKey[] memory assetPoolKeys;
        if (isManaged) {
            ManagedPortfolio memory portfolio = managedPortfolios[portfolioId];
            address[] memory assetAddresses = portfolio.currentAssetAddresses;
            assetList = new Asset[](assetAddresses.length);
            assetPoolKeys = new PoolKey[](assetAddresses.length);

            for (uint8 i = 0; i < assetAddresses.length; i++) {
                assetList[i] = managedPortfolioCurrentAssets[portfolioId][assetAddresses[i]];
                bytes32 hash = _hashPair(portfolio.inputToken, assetList[i].token);
                assetPoolKeys[i] = _pairToPoolKey[hash];
            }
        } else {
            Portfolio memory portfolio = portfolios[portfolioId];
            address[] memory assetAddresses = portfolio.assetAddresses;
            assetList = new Asset[](assetAddresses.length);
            assetPoolKeys = new PoolKey[](assetAddresses.length);

            for (uint8 i = 0; i < assetAddresses.length; i++) {
                assetList[i] = portfolioAssets[portfolioId][assetAddresses[i]];
                bytes32 hash = _hashPair(portfolio.inputToken, assetList[i].token);
                assetPoolKeys[i] = _pairToPoolKey[hash];
            }
        }

        // https://docs.uniswap.org/contracts/v4/concepts/lock-mechanism
        // lock was renamed to unlock --> https://github.com/Uniswap/v4-core/pull/508
        return uint256(bytes32(poolManager.unlock(abi.encodeCall(this._nav, (assetList, assetPoolKeys)))));
    }

    function _nav(Asset[] memory assetList, PoolKey[] memory assetPoolKeys) external view selfOnly returns (uint256) {
        uint256 navSqrtPriceX96;
        for (uint8 i = 0; i < assetList.length; i++) {
            uint256 amount = assetList[i].amountHeld / 10 ** assetList[i].decimals;
            // (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(assetPoolKeys[i].toId());
            navSqrtPriceX96 += (amount * sqrtPriceX96);
        }
        return navSqrtPriceX96;
    }

    /*
        Getters
    */

    function get(uint256 id) public view returns (Portfolio memory) {
        return portfolios[id];
    }

    function getManaged(uint256 id) public view returns (ManagedPortfolio memory) {
        return managedPortfolios[id];
    }

    /*
        Hackathon Helpers
        PortfolioManager needs a way to know about pools in PoolManager
        In the future, we will use Uniswap's default router
    */

    function _addPair(PoolKey memory poolKey) public returns (PoolId) {
        address a = address(Currency.unwrap(poolKey.currency0));
        address b = address(Currency.unwrap(poolKey.currency1));
        bytes32 hash = _hashPair(a, b);
        _pairToPoolKey[hash] = poolKey;
        return poolKey.toId();
    }

    function _hashPair(address a, address b) public pure returns (bytes32) {
        address currency0;
        address currency1;

        if (a < b) {
            currency0 = a;
            currency1 = b;
        } else {
            currency0 = b;
            currency1 = a;
        }
        return keccak256(abi.encode(currency0, currency1));
    }

    /*
        Utilities
    */

    function _id() internal returns (uint256) {
        return ++_portfolioId;
    }

    function _fee(uint256 portfolioId) internal view returns (uint24) {
        // discount fees for swaps pushing portfolio token price closer to NAV

        // if pt price < nav/shares --> discount buys
        // if pt price > nav/shares --> discount sells

        // compare [nav / totalshares] to tick-->price
        return 1;
    }

    function _hash(Asset[] memory assetList, address inputToken, uint8 rebalanceFrequency)
        internal
        pure
        returns (bytes32)
    {
        if (assetList.length > ASSET_LIST_MAXIMUM_LENGTH || assetList.length < ASSET_LIST_MINIMUM_LENGTH) {
            revert InvalidAssetList();
        }

        uint256 totalWeight = assetList[0].targetWeight;

        for (uint256 i = 1; i < assetList.length; i++) {
            // addresses must be sorted to check for and ensure uniqueness
            if (assetList[i - 1].token >= assetList[i].token) {
                revert InvalidAssetList();
            }
            totalWeight += assetList[i].targetWeight;
        }

        // asset weights must total 100%
        if (totalWeight != ASSET_WEIGHT_SUM) {
            revert InvalidAssetWeightSum();
        }

        return keccak256(abi.encode(assetList, inputToken, rebalanceFrequency));
    }

    /*
        Modifiers
    */

    modifier onlyManager(uint256 portfolioId) {
        if (msg.sender != managedPortfolios[portfolioId].manager) {
            revert InvalidPortfolioManager();
        }
        _;
    }

    modifier validateId(uint256 portfolioId) {
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
