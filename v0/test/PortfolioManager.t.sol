// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Deployers, MockERC20, SortTokens} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {
    Currency,
    CurrencyLibrary,
    Hooks,
    IHooks,
    IPoolManager,
    LPFeeLibrary,
    PoolClaimsTest,
    PoolId,
    PoolIdLibrary,
    PoolKey,
    PoolModifyLiquidityTest,
    PoolSwapTest,
    PortfolioManager,
    StateLibrary
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
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PortfolioManagerHarness public pm;

    Currency public eth = CurrencyLibrary.NATIVE;
    Currency public stablecoin;
    Currency public wbtc;
    Currency public wsol;
    Currency public uni;

    uint24 public constant FEE = 3000;
    IHooks public constant NO_HOOK = IHooks(address(0));

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
        deployTokensAndPools();
    }

    function deployTokensAndPools() public {
        stablecoin = deployMintAndApproveCurrency();

        Currency currency0;
        Currency currency1;
        PoolKey memory key;
        PoolId id;

        wbtc = deployMintAndApproveCurrency();
        (currency0, currency1) =
            SortTokens.sort(MockERC20(Currency.unwrap(stablecoin)), MockERC20(Currency.unwrap(wbtc)));
        (key,) = initPoolAndAddLiquidity(currency0, currency1, NO_HOOK, FEE, SQRT_PRICE_1_1, ZERO_BYTES);
        pm._addPair(key);
        (key,) = initPoolAndAddLiquidityETH(eth, wbtc, NO_HOOK, FEE, SQRT_PRICE_1_2, ZERO_BYTES, 10 ether);
        pm._addPair(key);

        wsol = deployMintAndApproveCurrency();
        (currency0, currency1) =
            SortTokens.sort(MockERC20(Currency.unwrap(stablecoin)), MockERC20(Currency.unwrap(wsol)));
        (key,) = initPoolAndAddLiquidity(currency0, currency1, NO_HOOK, FEE, SQRT_PRICE_2_1, ZERO_BYTES);
        pm._addPair(key);
        (key,) = initPoolAndAddLiquidityETH(eth, wsol, NO_HOOK, FEE, SQRT_PRICE_1_4, ZERO_BYTES, 10 ether);
        pm._addPair(key);

        uni = deployMintAndApproveCurrency();
        (currency0, currency1) =
            SortTokens.sort(MockERC20(Currency.unwrap(stablecoin)), MockERC20(Currency.unwrap(uni)));
        (key,) = initPoolAndAddLiquidity(currency0, currency1, NO_HOOK, FEE, SQRT_PRICE_4_1, ZERO_BYTES);
        pm._addPair(key);
        (key, id) = initPoolAndAddLiquidityETH(eth, uni, NO_HOOK, FEE, SQRT_PRICE_1_1, ZERO_BYTES, 10 ether);
        pm._addPair(key);
    }

    function sortAssets(PortfolioManager.Asset[] memory assets) public pure returns (PortfolioManager.Asset[] memory) {
        for (uint256 i = assets.length - 1; i > 0; i--) {
            for (uint256 j = 0; j < i; j++) {
                if (assets[i].token < assets[j].token) {
                    (assets[i], assets[j]) = (assets[j], assets[i]);
                }
            }
        }

        return assets;
    }

    function test_create_navUnlock() public {
        PortfolioManager.Asset[] memory assets = new PortfolioManager.Asset[](3);
        assets[0] = PortfolioManager.Asset(address(Currency.unwrap(eth)), 18, 30_000, 0);
        assets[1] = PortfolioManager.Asset(address(Currency.unwrap(wbtc)), 18, 50_000, 0);
        assets[2] = PortfolioManager.Asset(address(Currency.unwrap(wsol)), 18, 20_000, 0);

        uint256 id = pm.create(sortAssets(assets), address(Currency.unwrap(stablecoin)), 30, false);
        console.logUint(pm.nav(id, false));
    }

    function test_create_navTest() public {
        PortfolioManager.Asset[] memory assets = new PortfolioManager.Asset[](3);
        assets[0] = PortfolioManager.Asset(address(Currency.unwrap(eth)), 18, 30_000, 0);
        assets[1] = PortfolioManager.Asset(address(Currency.unwrap(wbtc)), 18, 50_000, 0);
        assets[2] = PortfolioManager.Asset(address(Currency.unwrap(wsol)), 18, 20_000, 0);
        uint256 id = pm.create(sortAssets(assets), address(Currency.unwrap(stablecoin)), 30, false);
        console.logUint(pm.navTest(id, false));
    }

    function test_addPair() public {
        (Currency currency0, Currency currency1) = deployMintAndApprove2Currencies();
        (PoolKey memory poolKey,) =
            initPoolAndAddLiquidity(currency0, currency1, NO_HOOK, FEE, SQRT_PRICE_4_1, ZERO_BYTES);

        pm._addPair(poolKey);

        bytes32 hash = pm._hashPair(address(Currency.unwrap(currency0)), address(Currency.unwrap(currency1)));

        (Currency _currency0, Currency _currency1, uint24 _fee, int24 _tickSpacing, IHooks _hooks) =
            pm._pairToPoolKey(hash);
        PoolKey memory _poolKey = PoolKey(_currency0, _currency1, _fee, _tickSpacing, _hooks);

        assertEq(abi.encode(_poolKey.toId()), abi.encode(poolKey.toId()));
    }

    function testFuzz_hashPair(address a, address b) public view {
        address currency0;
        address currency1;

        if (a < b) {
            currency0 = a;
            currency1 = b;
        } else {
            currency0 = b;
            currency1 = a;
        }

        assertEq(pm._hashPair(a, b), keccak256(abi.encode(currency0, currency1)));
    }

    function test_id() public {
        assertEq(pm.exposed_id(), 1);
        assertEq(pm.exposed_id(), 2);
        assertEq(pm.exposed_id(), 3);
    }
}
