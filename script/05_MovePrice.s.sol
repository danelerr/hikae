// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Addresses} from "./Addresses.sol";

/// @notice Step 5, Base Sepolia: swap on the reference pool to move its price. This is the event Reflejo reacts to.
/// Needs REF_TOKEN0 and REF_TOKEN1. Optional: ZERO_FOR_ONE (default true), AMOUNT in wei (default 50 tokens).
/// forge script script/05_MovePrice.s.sol --rpc-url base_sepolia --broadcast
contract MovePrice is Script {
    function run() external {
        require(block.chainid == Addresses.BASE_SEPOLIA, "run on Base Sepolia");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        Currency c0 = Currency.wrap(vm.envAddress("REF_TOKEN0"));
        Currency c1 = Currency.wrap(vm.envAddress("REF_TOKEN1"));
        bool zeroForOne = vm.envOr("ZERO_FOR_ONE", true);
        int256 amount = int256(vm.envOr("AMOUNT", uint256(50 ether)));

        PoolKey memory key = PoolKey(c0, c1, 3000, Addresses.TICK_SPACING, IHooks(address(0)));

        vm.startBroadcast(pk);
        PoolSwapTest(Addresses.BASE_SWAP_ROUTER).swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();

        console2.log("swapped on the reference pool, zeroForOne=%s", zeroForOne);
    }
}
