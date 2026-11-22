// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Addresses} from "./Addresses.sol";

/// @notice Shared helpers: two test tokens, a pool at price 1:1 and wide liquidity around it.
abstract contract PoolSetup is Script {
    uint256 internal constant MINT_AMOUNT = 1_000_000 ether;

    /// @dev The two pools live on different chains with different token addresses. To make a tick mean the same
    /// price on both, rUSD must be token0 on both: the lower of the next two CREATE addresses gets rUSD.
    function _deployTokenPair(address owner, address[2] memory spenders) internal returns (Currency, Currency) {
        uint64 nonce = vm.getNonce(owner);
        address first = vm.computeCreateAddress(owner, nonce);
        address second = vm.computeCreateAddress(owner, nonce + 1);
        bool usdFirst = first < second;

        MockERC20 x = usdFirst
            ? new MockERC20("Reflejo Test USD", "rUSD", 18)
            : new MockERC20("Reflejo Test ETH", "rETH", 18);
        MockERC20 y = usdFirst
            ? new MockERC20("Reflejo Test ETH", "rETH", 18)
            : new MockERC20("Reflejo Test USD", "rUSD", 18);
        require(address(x) == first && address(y) == second, "unexpected token address");

        (MockERC20 usd, MockERC20 eth) = usdFirst ? (x, y) : (y, x);
        require(address(usd) < address(eth), "rUSD must be token0");
        usd.mint(owner, MINT_AMOUNT);
        eth.mint(owner, MINT_AMOUNT);
        for (uint256 i; i < spenders.length; i++) {
            usd.approve(spenders[i], type(uint256).max);
            eth.approve(spenders[i], type(uint256).max);
        }
        return (Currency.wrap(address(usd)), Currency.wrap(address(eth)));
    }

    function _initWithLiquidity(
        IPoolManager manager,
        PoolModifyLiquidityTest liquidityRouter,
        Currency currency0,
        Currency currency1,
        uint24 fee,
        IHooks hooks
    ) internal returns (PoolKey memory key) {
        key = PoolKey(currency0, currency1, fee, Addresses.TICK_SPACING, hooks);
        manager.initialize(key, Addresses.SQRT_PRICE_1_1);
        liquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100_000 ether, salt: 0}), ""
        );
    }
}
