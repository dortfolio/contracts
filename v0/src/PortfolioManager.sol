// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary, PoolKey} from "v4-core/types/PoolId.sol";

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {PoolClaimsTest} from "v4-core/test/PoolClaimsTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {BaseHook, Hooks, IHooks, IPoolManager} from "v4-periphery/BaseHook.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {PortfolioToken, ERC20} from "./PortfolioToken.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

contract PortfolioManager is BaseHook {
    using CurrencySettler for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 public constant ASSET_LIST_MAXIMUM_LENGTH = 20;
    uint256 public constant ASSET_LIST_MINIMUM_LENGTH = 2;
    uint256 internal constant ASSET_WEIGHT_SUM = 100_000;
    uint24 public constant DEFAULT_SWAP_FEE = 1000;
    uint24 public constant DISCOUNTED_SWAP_FEE = 500;
    uint8 public constant MANAGED_PORTFOLIO_MANAGEMENT_FEE = 10;
    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    bytes constant ZERO_BYTES = new bytes(0);

    struct Asset {
        address token; // address(0) = eth
        uint256 decimals;
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

    struct Swap {
        PoolKey poolKey;
        IPoolManager.SwapParams swapParams;
        PoolSwapTest.TestSettings testSettings;
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
    error InvalidBalanceDelta();
    error InvalidBurnAmount();
    error InvalidMintSpenderAddress();
    error InvalidPortfolioId();
    error InvalidPortfolioInputToken();
    error InvalidPortfolioManager();
    error InvalidPortfolioUpdate();
    error InvalidManagementFeeTransfer();
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

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata swapParams, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 portfolioId = poolIdToId[key.toId()];
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, _fee(portfolioId, key, swapParams));
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
                managementFeeBasisPoints: MANAGED_PORTFOLIO_MANAGEMENT_FEE,
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

    function rebalance(uint256 portfolioId) public validateId(portfolioId) returns (bool didRebalance) {
        bool isManaged = idToIsManaged[portfolioId];

        if (isManaged) {
            didRebalance = _rebalanceManagedPortfolio(portfolioId);
        } else {
            didRebalance = _rebalanceAutomatedPortfolio(portfolioId);
        }
    }

    function _rebalanceAutomatedPortfolio(uint256 portfolioId) internal returns (bool) {
        Portfolio storage p = portfolios[portfolioId];

        if (block.timestamp < p.rebalancedAt + (p.rebalanceFrequency * 1 days)) {
            return false;
        }

        Swap[] memory swapList = new Swap[](p.assetAddresses.length);
        uint24[] memory weightList = new uint24[](p.assetAddresses.length);

        for (uint8 i = 0; i < p.assetAddresses.length; i++) {
            Asset memory asset = portfolioAssets[portfolioId][p.assetAddresses[i]];

            swapList[i] = Swap({
                poolKey: _pairToPoolKey[_hashPair(p.inputToken, asset.token)],
                swapParams: IPoolManager.SwapParams({
                    zeroForOne: asset.token < p.inputToken,
                    amountSpecified: -1 * int256(asset.amountHeld),
                    sqrtPriceLimitX96: asset.token < p.inputToken ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                testSettings: PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: true})
            });

            weightList[i] = asset.targetWeight;
        }
        uint256[] memory assetAmounts = abi.decode(
            poolManager.unlock(
                abi.encodeCall(this._rebalanceAutomatedPortfolioUnlockCallback, (address(this), swapList, weightList))
            ),
            (uint256[])
        );

        for (uint8 i = 0; i < p.assetAddresses.length; i++) {
            Asset storage asset = portfolioAssets[portfolioId][p.assetAddresses[i]];
            asset.amountHeld = assetAmounts[i];
        }

        p.rebalancedAt = block.timestamp;
        return true;
    }

    function _rebalanceAutomatedPortfolioUnlockCallback(
        address portfolioManager,
        Swap[] calldata swapList,
        uint24[] memory weightList
    ) external selfOnly returns (uint256[] memory) {
        uint256 inputTokenTotal;

        for (uint8 i = 0; i < swapList.length; i++) {
            Swap memory swap = swapList[i];

            // Use poolManager.swap instead of swapRouter.swap because the latter calls unlock
            BalanceDelta balanceDelta = poolManager.swap(swap.poolKey, swap.swapParams, ZERO_BYTES);
            int128 amount0 = BalanceDeltaLibrary.amount0(balanceDelta);
            int128 amount1 = BalanceDeltaLibrary.amount1(balanceDelta);

            // asset for inputToken
            if (swap.swapParams.zeroForOne) {
                swap.poolKey.currency0.settle(
                    poolManager, portfolioManager, uint128(-amount0), swap.testSettings.settleUsingBurn
                );
                swap.poolKey.currency1.take(
                    poolManager, portfolioManager, uint128(amount1), swap.testSettings.takeClaims
                );
                inputTokenTotal += uint128(amount1);
            } else {
                swap.poolKey.currency1.settle(
                    poolManager, portfolioManager, uint128(-amount1), swap.testSettings.settleUsingBurn
                );
                swap.poolKey.currency0.take(
                    poolManager, portfolioManager, uint128(amount0), swap.testSettings.takeClaims
                );

                inputTokenTotal += uint128(amount0);
            }
        }

        uint256[] memory assetAmounts = new uint256[](swapList.length);

        for (uint8 i = 0; i < swapList.length; i++) {
            Swap memory lastSwap = swapList[i];

            // flip to inputToken for asset
            bool zeroForOne = !lastSwap.swapParams.zeroForOne;
            IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -1 * int256(inputTokenTotal * weightList[i] / ASSET_WEIGHT_SUM),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            });

            BalanceDelta balanceDelta = poolManager.swap(lastSwap.poolKey, swapParams, ZERO_BYTES);
            int128 amount0 = BalanceDeltaLibrary.amount0(balanceDelta);
            int128 amount1 = BalanceDeltaLibrary.amount1(balanceDelta);

            // inputToken for asset
            if (swapParams.zeroForOne) {
                lastSwap.poolKey.currency0.settle(
                    poolManager, portfolioManager, uint128(-amount0), lastSwap.testSettings.settleUsingBurn
                );
                lastSwap.poolKey.currency1.take(
                    poolManager, portfolioManager, uint128(amount1), lastSwap.testSettings.takeClaims
                );
                assetAmounts[i] = uint128(amount1);
            } else {
                lastSwap.poolKey.currency1.settle(
                    poolManager, portfolioManager, uint128(-amount1), lastSwap.testSettings.settleUsingBurn
                );
                lastSwap.poolKey.currency0.take(
                    poolManager, portfolioManager, uint128(amount0), lastSwap.testSettings.takeClaims
                );
                assetAmounts[i] = uint128(amount0);
            }
        }
        return assetAmounts;
    }

    function _rebalanceManagedPortfolio(uint256 portfolioId) internal returns (bool) {
        ManagedPortfolio storage mp = managedPortfolios[portfolioId];

        if (block.timestamp < mp.rebalancedAt + (mp.rebalanceFrequency * 1 days)) {
            return false;
        }

        Swap[] memory deallocateSwapList = new Swap[](mp.currentAssetAddresses.length);

        for (uint8 i = 0; i < mp.currentAssetAddresses.length; i++) {
            Asset storage asset = managedPortfolioCurrentAssets[portfolioId][mp.currentAssetAddresses[i]];

            deallocateSwapList[i] = Swap({
                poolKey: _pairToPoolKey[_hashPair(mp.inputToken, asset.token)],
                swapParams: IPoolManager.SwapParams({
                    zeroForOne: asset.token < mp.inputToken,
                    amountSpecified: -1 * int256(asset.amountHeld),
                    sqrtPriceLimitX96: asset.token < mp.inputToken ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                testSettings: PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: true})
            });

            asset.amountHeld = 0;
            asset.targetWeight = 0;
        }

        Swap[] memory allocateSwapList = new Swap[](mp.targetAssetAddresses.length);
        uint24[] memory allocateWeightList = new uint24[](mp.targetAssetAddresses.length);

        for (uint8 i = 0; i < mp.targetAssetAddresses.length; i++) {
            Asset memory asset = managedPortfolioTargetAssets[portfolioId][mp.targetAssetAddresses[i]];

            allocateSwapList[i] = Swap({
                poolKey: _pairToPoolKey[_hashPair(mp.inputToken, asset.token)],
                swapParams: IPoolManager.SwapParams({
                    zeroForOne: mp.inputToken < asset.token,
                    amountSpecified: 0, // set during unlock
                    sqrtPriceLimitX96: mp.inputToken < asset.token ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                testSettings: PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: true})
            });

            allocateWeightList[i] = asset.targetWeight;
        }

        (uint256[] memory targetAssetAmounts) = abi.decode(
            poolManager.unlock(
                abi.encodeCall(
                    this._rebalanceManagedPortfolioUnlockCallback,
                    (address(this), deallocateSwapList, allocateSwapList, allocateWeightList)
                )
            ),
            (uint256[])
        );

        // if (address(mp.inputToken) == address(0)) {
        //     (bool sent,) = address(mp.manager).call{value: managementFee}("");
        //     if (!sent) {
        //         revert InvalidManagementFeeTransfer();
        //     }
        // } else {
        //     ERC20(mp.inputToken).transfer(mp.manager, managementFee);
        // }

        for (uint8 i = 0; i < mp.targetAssetAddresses.length; i++) {
            Asset storage asset = managedPortfolioTargetAssets[portfolioId][mp.targetAssetAddresses[i]];
            asset.amountHeld = targetAssetAmounts[i];
            managedPortfolioCurrentAssets[portfolioId][mp.targetAssetAddresses[i]] = asset;
        }

        mp.rebalancedAt = block.timestamp;
        mp.currentAssetAddresses = mp.targetAssetAddresses;
        return true;
    }

    function _rebalanceManagedPortfolioUnlockCallback(
        address portfolioManager,
        Swap[] calldata deallocateSwapList,
        Swap[] calldata allocateSwapList,
        uint24[] memory allocateWeightList
    ) external selfOnly returns (uint256[] memory) {
        uint256 inputTokenTotal;

        for (uint8 i = 0; i < deallocateSwapList.length; i++) {
            Swap memory swap = deallocateSwapList[i];

            // Use poolManager.swap instead of swapRouter.swap because the latter calls unlock
            BalanceDelta balanceDelta = poolManager.swap(swap.poolKey, swap.swapParams, ZERO_BYTES);
            int128 amount0 = BalanceDeltaLibrary.amount0(balanceDelta);
            int128 amount1 = BalanceDeltaLibrary.amount1(balanceDelta);

            // asset for inputToken
            if (swap.swapParams.zeroForOne) {
                swap.poolKey.currency0.settle(
                    poolManager, portfolioManager, uint128(-amount0), swap.testSettings.settleUsingBurn
                );
                swap.poolKey.currency1.take(
                    poolManager, portfolioManager, uint128(amount1), swap.testSettings.takeClaims
                );
                inputTokenTotal += uint128(amount1);
            } else {
                swap.poolKey.currency1.settle(
                    poolManager, portfolioManager, uint128(-amount1), swap.testSettings.settleUsingBurn
                );
                swap.poolKey.currency0.take(
                    poolManager, portfolioManager, uint128(amount0), swap.testSettings.takeClaims
                );

                inputTokenTotal += uint128(amount0);
            }
        }

        uint256[] memory targetAssetAmounts = new uint256[](allocateSwapList.length);

        for (uint8 i = 0; i < allocateSwapList.length; i++) {
            Swap memory swap = allocateSwapList[i];
            swap.swapParams.amountSpecified = -1 * int256(inputTokenTotal * allocateWeightList[i] / ASSET_WEIGHT_SUM);

            BalanceDelta balanceDelta = poolManager.swap(swap.poolKey, swap.swapParams, ZERO_BYTES);
            int128 amount0 = BalanceDeltaLibrary.amount0(balanceDelta);
            int128 amount1 = BalanceDeltaLibrary.amount1(balanceDelta);

            // inputToken for asset
            if (swap.swapParams.zeroForOne) {
                swap.poolKey.currency0.settle(
                    poolManager, portfolioManager, uint128(-amount0), swap.testSettings.settleUsingBurn
                );
                swap.poolKey.currency1.take(
                    poolManager, portfolioManager, uint128(amount1), swap.testSettings.takeClaims
                );
                targetAssetAmounts[i] = uint128(amount1);
            } else {
                swap.poolKey.currency1.settle(
                    poolManager, portfolioManager, uint128(-amount1), swap.testSettings.settleUsingBurn
                );
                swap.poolKey.currency0.take(
                    poolManager, portfolioManager, uint128(amount0), swap.testSettings.takeClaims
                );
                targetAssetAmounts[i] = uint128(amount0);
            }
        }
        return targetAssetAmounts;
    }

    function nav(uint256 portfolioId, bool isManaged) public returns (uint256 navSqrtX96) {
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
        return abi.decode(poolManager.unlock(abi.encodeCall(this._nav, (assetList, assetPoolKeys))), (uint256));
    }

    function _nav(Asset[] memory assetList, PoolKey[] memory assetPoolKeys) external view selfOnly returns (uint256) {
        uint256 navSqrtX96;
        for (uint8 i = 0; i < assetList.length; i++) {
            uint256 amount = _normalizeTokenAmount(assetList[i].amountHeld, assetList[i].decimals);
            // (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(assetPoolKeys[i].toId());
            if (address(Currency.unwrap(assetPoolKeys[i].currency0)) == assetList[i].token) {
                navSqrtX96 += (amount * sqrtPriceX96);
            } else {
                navSqrtX96 += (amount / sqrtPriceX96);
            }
        }
        return navSqrtX96;
    }
    //
    // Inline instead of unlock
    // function nav(uint256 portfolioId, bool isManaged) public view returns (uint256 navSqrtX96) {
    //     Asset[] memory assetList;
    //     PoolKey[] memory assetPoolKeys;
    //     if (isManaged) {
    //         ManagedPortfolio memory portfolio = managedPortfolios[portfolioId];
    //         address[] memory assetAddresses = portfolio.currentAssetAddresses;
    //         assetList = new Asset[](assetAddresses.length);
    //         assetPoolKeys = new PoolKey[](assetAddresses.length);

    //         for (uint8 i = 0; i < assetAddresses.length; i++) {
    //             assetList[i] = managedPortfolioCurrentAssets[portfolioId][assetAddresses[i]];
    //             bytes32 hash = _hashPair(portfolio.inputToken, assetList[i].token);
    //             assetPoolKeys[i] = _pairToPoolKey[hash];
    //         }
    //     } else {
    //         Portfolio memory portfolio = portfolios[portfolioId];
    //         address[] memory assetAddresses = portfolio.assetAddresses;
    //         assetList = new Asset[](assetAddresses.length);
    //         assetPoolKeys = new PoolKey[](assetAddresses.length);

    //         for (uint8 i = 0; i < assetAddresses.length; i++) {
    //             assetList[i] = portfolioAssets[portfolioId][assetAddresses[i]];
    //             bytes32 hash = _hashPair(portfolio.inputToken, assetList[i].token);
    //             assetPoolKeys[i] = _pairToPoolKey[hash];
    //         }
    //     }

    //     for (uint8 i = 0; i < assetList.length; i++) {
    //         uint256 amount = _normalizeTokenAmount(assetList[i].amountHeld, assetList[i].decimals);
    //         (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(assetPoolKeys[i].toId());
    //         if (address(Currency.unwrap(assetPoolKeys[i].currency0)) == assetList[i].token) {
    //             navSqrtX96 += (amount * sqrtPriceX96);
    //         } else {
    //             navSqrtX96 += (amount / sqrtPriceX96);
    //         }
    //     }
    //     return navSqrtX96;
    // }

    /*
        Portfolio Tokens
    */

    // ETH
    function mint(uint256 portfolioId) public payable validateId(portfolioId) {
        claimsRouter.deposit(Currency.wrap(address(0)), address(this), msg.value);
        bool isManaged = idToIsManaged[portfolioId];

        uint256 navSqrtX96 = nav(portfolioId, isManaged);
        uint256 amountSqrtX96 = FixedPointMathLib.sqrt(msg.value);
        if (isManaged) {
            managedPortfolios[portfolioId].portfolioToken.mint(msg.sender, amountSqrtX96 / navSqrtX96);
        } else {
            portfolios[portfolioId].portfolioToken.mint(msg.sender, amountSqrtX96 / navSqrtX96);
        }

        _allocate(portfolioId, msg.value, isManaged);
        rebalance(portfolioId);
    }

    // ERC-20
    function mint(
        uint256 portfolioId,
        ERC20 inputToken,
        address owner,
        address spender,
        uint256 inputTokenAmount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public validateId(portfolioId) {
        if (spender != address(this)) {
            revert InvalidMintSpenderAddress();
        }
        inputToken.permit(owner, spender, inputTokenAmount, deadline, v, r, s);
        inputToken.transferFrom(owner, spender, inputTokenAmount);
        claimsRouter.deposit(Currency.wrap(address(inputToken)), address(this), inputTokenAmount);

        bool isManaged = idToIsManaged[portfolioId];

        uint256 navSqrtX96 = nav(portfolioId, isManaged);
        uint256 amountSqrtX96 =
            FixedPointMathLib.sqrt(_normalizeTokenAmount(inputTokenAmount, inputToken.decimals()) * (2 ** 96));
        if (isManaged) {
            managedPortfolios[portfolioId].portfolioToken.mint(owner, amountSqrtX96 / navSqrtX96);
        } else {
            portfolios[portfolioId].portfolioToken.mint(owner, amountSqrtX96 / navSqrtX96);
        }

        _allocate(portfolioId, inputTokenAmount, isManaged);
        rebalance(portfolioId);
    }

    function _allocate(uint256 portfolioId, uint256 inputTokenAmount, bool isManaged) internal {
        address[] memory assetAddresses;
        address inputToken;

        if (isManaged) {
            assetAddresses = managedPortfolios[portfolioId].currentAssetAddresses;
            inputToken = managedPortfolios[portfolioId].inputToken;
        } else {
            assetAddresses = portfolios[portfolioId].assetAddresses;
            inputToken = portfolios[portfolioId].inputToken;
        }

        Swap[] memory swapList = new Swap[](assetAddresses.length);

        for (uint8 i = 0; i < assetAddresses.length; i++) {
            Asset memory asset;
            if (isManaged) {
                asset = managedPortfolioCurrentAssets[portfolioId][assetAddresses[i]];
            } else {
                asset = portfolioAssets[portfolioId][assetAddresses[i]];
            }

            swapList[i] = Swap({
                poolKey: _pairToPoolKey[_hashPair(inputToken, asset.token)],
                swapParams: IPoolManager.SwapParams({
                    zeroForOne: inputToken < asset.token,
                    amountSpecified: -1 * int256(inputTokenAmount),
                    sqrtPriceLimitX96: inputToken < asset.token ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                testSettings: PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: true})
            });
        }

        uint256[] memory assetAmounts = abi.decode(
            poolManager.unlock(abi.encodeCall(this._allocateUnlockCallback, (address(this), swapList))), (uint256[])
        );

        for (uint8 i = 0; i < assetAddresses.length; i++) {
            Asset storage asset;
            if (isManaged) {
                asset = managedPortfolioCurrentAssets[portfolioId][assetAddresses[i]];
            } else {
                asset = portfolioAssets[portfolioId][assetAddresses[i]];
            }
            asset.amountHeld += assetAmounts[i];
        }
    }

    function _allocateUnlockCallback(address portfolioManager, Swap[] calldata swapList)
        external
        selfOnly
        returns (uint256[] memory)
    {
        uint256[] memory assetAmounts = new uint256[](swapList.length);

        for (uint8 i = 0; i < swapList.length; i++) {
            Swap memory swap = swapList[i];

            // Use poolManager.swap instead of swapRouter.swap because the latter calls unlock
            BalanceDelta balanceDelta = poolManager.swap(swap.poolKey, swap.swapParams, ZERO_BYTES);
            int128 amount0 = BalanceDeltaLibrary.amount0(balanceDelta);
            int128 amount1 = BalanceDeltaLibrary.amount1(balanceDelta);

            // inputToken for assetToken
            if (swap.swapParams.zeroForOne) {
                swap.poolKey.currency0.settle(
                    poolManager, portfolioManager, uint128(-amount0), swap.testSettings.settleUsingBurn
                );
                swap.poolKey.currency1.take(
                    poolManager, portfolioManager, uint128(amount1), swap.testSettings.takeClaims
                );
                assetAmounts[i] = uint128(amount1);
            } else {
                swap.poolKey.currency1.settle(
                    poolManager, portfolioManager, uint128(-amount1), swap.testSettings.settleUsingBurn
                );
                swap.poolKey.currency0.take(
                    poolManager, portfolioManager, uint128(amount0), swap.testSettings.takeClaims
                );
                assetAmounts[i] = uint128(amount0);
            }
        }
        return assetAmounts;
    }

    function burn(uint256 portfolioId, uint256 portfolioTokenAmount) public validateId(portfolioId) {
        uint256 portfolioTokenTotalSupply;
        bool isManaged = idToIsManaged[portfolioId];

        if (isManaged) {
            ManagedPortfolio memory managedPortfolio = managedPortfolios[portfolioId];
            if (managedPortfolio.portfolioToken.balanceOf(msg.sender) < portfolioTokenAmount) {
                revert InvalidBurnAmount();
            }
            portfolioTokenTotalSupply = managedPortfolio.portfolioToken.totalSupply();
            managedPortfolios[portfolioId].portfolioToken.burn(msg.sender, portfolioTokenAmount);
        } else {
            Portfolio memory portfolio = portfolios[portfolioId];
            if (portfolio.portfolioToken.balanceOf(msg.sender) < portfolioTokenAmount) {
                revert InvalidBurnAmount();
            }
            portfolioTokenTotalSupply = portfolio.portfolioToken.totalSupply();
            portfolios[portfolioId].portfolioToken.burn(msg.sender, portfolioTokenAmount);
        }

        _deallocate(portfolioId, portfolioTokenAmount, portfolioTokenTotalSupply, isManaged);
        rebalance(portfolioId);
    }

    function _deallocate(
        uint256 portfolioId,
        uint256 portfolioTokenAmount,
        uint256 portfolioTokenTotalSupply,
        bool isManaged
    ) internal {
        address[] memory assetAddresses;
        address inputToken;

        if (isManaged) {
            assetAddresses = managedPortfolios[portfolioId].currentAssetAddresses;
            inputToken = managedPortfolios[portfolioId].inputToken;
        } else {
            assetAddresses = portfolios[portfolioId].assetAddresses;
            inputToken = portfolios[portfolioId].inputToken;
        }

        Swap[] memory swapList = new Swap[](assetAddresses.length);

        for (uint8 i = 0; i < assetAddresses.length; i++) {
            Asset memory asset;
            if (isManaged) {
                asset = managedPortfolioCurrentAssets[portfolioId][assetAddresses[i]];
            } else {
                asset = portfolioAssets[portfolioId][assetAddresses[i]];
            }

            swapList[i] = Swap({
                poolKey: _pairToPoolKey[_hashPair(inputToken, asset.token)],
                swapParams: IPoolManager.SwapParams({
                    zeroForOne: asset.token < inputToken,
                    amountSpecified: -1
                        * int256(
                            asset.amountHeld * portfolioTokenAmount / portfolioTokenTotalSupply * asset.targetWeight
                                / ASSET_WEIGHT_SUM
                        ),
                    sqrtPriceLimitX96: asset.token < inputToken ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                testSettings: PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: true})
            });
        }

        uint256[] memory assetAmounts = abi.decode(
            poolManager.unlock(abi.encodeCall(this._deallocateUnlockCallback, (address(this), swapList))), (uint256[])
        );

        for (uint8 i = 0; i < assetAddresses.length; i++) {
            Asset storage asset;
            if (isManaged) {
                asset = managedPortfolioCurrentAssets[portfolioId][assetAddresses[i]];
            } else {
                asset = portfolioAssets[portfolioId][assetAddresses[i]];
            }
            asset.amountHeld -= assetAmounts[i];
        }
    }

    function _deallocateUnlockCallback(address portfolioManager, Swap[] calldata swapList)
        external
        selfOnly
        returns (uint256[] memory)
    {
        uint256[] memory assetAmounts = new uint256[](swapList.length);

        for (uint8 i = 0; i < swapList.length; i++) {
            Swap memory swap = swapList[i];

            // Use poolManager.swap instead of swapRouter.swap because the latter calls unlock
            BalanceDelta balanceDelta = poolManager.swap(swap.poolKey, swap.swapParams, ZERO_BYTES);
            int128 amount0 = BalanceDeltaLibrary.amount0(balanceDelta);
            int128 amount1 = BalanceDeltaLibrary.amount1(balanceDelta);

            // asset for inputToken
            if (swap.swapParams.zeroForOne) {
                swap.poolKey.currency0.settle(
                    poolManager, portfolioManager, uint128(-amount0), swap.testSettings.settleUsingBurn
                );
                swap.poolKey.currency1.take(
                    poolManager, portfolioManager, uint128(amount1), swap.testSettings.takeClaims
                );
                assetAmounts[i] = uint128(-1 * amount0);
            } else {
                swap.poolKey.currency1.settle(
                    poolManager, portfolioManager, uint128(-amount1), swap.testSettings.settleUsingBurn
                );
                swap.poolKey.currency0.take(
                    poolManager, portfolioManager, uint128(amount0), swap.testSettings.takeClaims
                );

                assetAmounts[i] = uint128(-1 * amount1);
            }
        }
        return assetAmounts;
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

    function _fee(uint256 portfolioId, PoolKey calldata key, IPoolManager.SwapParams calldata swapParams)
        internal
        validateId(portfolioId)
        returns (uint24)
    {
        bool isManaged = idToIsManaged[portfolioId];
        uint256 navSqrtX96 = nav(portfolioId, isManaged);
        uint256 sqrtPriceX96;
        uint256 totalSupply;
        address portfolioToken;
        bool isBuy;

        if (isManaged) {
            ManagedPortfolio memory mp = managedPortfolios[portfolioId];
            (sqrtPriceX96,,,) = poolManager.getSlot0(mp.poolId);
            totalSupply = mp.portfolioToken.totalSupply();
            portfolioToken = address(mp.portfolioToken);
        } else {
            Portfolio memory p = portfolios[portfolioId];
            (sqrtPriceX96,,,) = poolManager.getSlot0(p.poolId);
            totalSupply = p.portfolioToken.totalSupply();
            portfolioToken = address(p.portfolioToken);
        }

        if (address(Currency.unwrap(key.currency0)) == address(portfolioToken)) {
            isBuy = !swapParams.zeroForOne;
        } else {
            isBuy = swapParams.zeroForOne;
        }

        // Discount fees for swaps pushing portfolio token price closer to NAV
        if (
            (sqrtPriceX96 < (navSqrtX96 / totalSupply) && isBuy)
                || (sqrtPriceX96 > (navSqrtX96 / totalSupply) && !isBuy)
        ) {
            return DISCOUNTED_SWAP_FEE;
        } else {
            return DEFAULT_SWAP_FEE;
        }
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

    // note: leads to truncation if tokenDecimals > 18
    // https://x.com/CharlesWangP/status/1742512078378725658
    function _normalizeTokenAmount(uint256 tokenAmount, uint256 tokenDecimals) internal pure returns (uint256) {
        uint256 defaultDecimals = 18;
        if (tokenDecimals > defaultDecimals) {
            return tokenAmount / (10 ** (tokenDecimals - defaultDecimals));
        } else if (tokenDecimals < defaultDecimals) {
            return tokenAmount * (10 ** (defaultDecimals - tokenDecimals));
        } else {
            return tokenAmount;
        }
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
