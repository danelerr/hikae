// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Addresses} from "./Addresses.sol";
import {PoolSetup} from "./PoolSetup.sol";

/// @notice Step 1, Base Sepolia: the reference pool whose price Reflejo watches.
/// forge script script/01_ReferencePool.s.sol --rpc-url base_sepolia --broadcast
contract ReferencePool is PoolSetup {
    using PoolIdLibrary for PoolKey;

    function run() external {
        require(block.chainid == Addresses.BASE_SEPOLIA, "run on Base Sepolia");
        address deployer = _signer();

        vm.startBroadcast();
        (Currency c0, Currency c1) =
            _deployTokenPair(deployer, [Addresses.BASE_MODIFY_LIQUIDITY, Addresses.BASE_SWAP_ROUTER]);
        PoolKey memory key = _initWithLiquidity(
            IPoolManager(Addresses.BASE_POOL_MANAGER),
            PoolModifyLiquidityTest(Addresses.BASE_MODIFY_LIQUIDITY),
            c0,
            c1,
            3000,
            IHooks(address(0))
        );
        vm.stopBroadcast();

        console2.log("REF_TOKEN0=%s", Currency.unwrap(c0));
        console2.log("REF_TOKEN1=%s", Currency.unwrap(c1));
        console2.log("REF_POOL_ID=%s", vm.toString(PoolId.unwrap(key.toId())));
    }
}
