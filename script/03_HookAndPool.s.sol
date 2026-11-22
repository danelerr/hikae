// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {HikaeHook} from "../src/HikaeHook.sol";
import {Addresses, IDepositTo} from "./Addresses.sol";
import {PoolSetup} from "./PoolSetup.sol";

/// @notice Step 3, Unichain Sepolia: mine the hook address, deploy the hook, fund its callbacks and create the
/// protected dynamic-fee pool. Needs REACTIVE from step 2. Optional: HOOK_FUNDING in wei (default 0.01 ether).
/// forge script script/03_HookAndPool.s.sol --rpc-url unichain_sepolia --broadcast
contract HookAndPool is PoolSetup {
    using PoolIdLibrary for PoolKey;

    function run() external {
        require(block.chainid == Addresses.UNICHAIN_SEPOLIA, "run on Unichain Sepolia");
        address deployer = _signer();
        address reactive = vm.envAddress("REACTIVE");
        uint256 funding = vm.envOr("HOOK_FUNDING", uint256(0.01 ether));

        HikaeHook.FeeConfig memory config =
            HikaeHook.FeeConfig({baseFee: 3000, captureBps: 6000, maxFee: 30000, maxAge: 120});
        bytes memory args = abi.encode(
            IPoolManager(Addresses.UNICHAIN_POOL_MANAGER), Addresses.UNICHAIN_CALLBACK_PROXY, reactive, deployer, config
        );
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        (address expected, bytes32 salt) =
            HookMiner.find(Addresses.CREATE2_DEPLOYER, flags, type(HikaeHook).creationCode, args);

        vm.startBroadcast();
        HikaeHook hook = new HikaeHook{salt: salt}(
            IPoolManager(Addresses.UNICHAIN_POOL_MANAGER), Addresses.UNICHAIN_CALLBACK_PROXY, reactive, deployer, config
        );
        require(address(hook) == expected, "hook address mismatch");

        // Callbacks are charged to the hook on Unichain; prepay so the first ones are not blocked by debt.
        IDepositTo(Addresses.UNICHAIN_CALLBACK_PROXY).depositTo{value: funding}(address(hook));

        (Currency c0, Currency c1) =
            _deployTokenPair(deployer, [Addresses.UNICHAIN_MODIFY_LIQUIDITY, Addresses.UNICHAIN_SWAP_ROUTER]);
        PoolKey memory key = _initWithLiquidity(
            IPoolManager(Addresses.UNICHAIN_POOL_MANAGER),
            PoolModifyLiquidityTest(Addresses.UNICHAIN_MODIFY_LIQUIDITY),
            c0,
            c1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            IHooks(address(hook))
        );
        vm.stopBroadcast();

        console2.log("HOOK=%s", address(hook));
        console2.log("DEST_TOKEN0=%s", Currency.unwrap(c0));
        console2.log("DEST_TOKEN1=%s", Currency.unwrap(c1));
        console2.log("DEST_POOL_ID=%s", vm.toString(PoolId.unwrap(key.toId())));
    }
}
