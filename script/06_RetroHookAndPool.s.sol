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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ReflejoHook} from "../src/ReflejoHook.sol";
import {ReflejoRetroHook} from "../src/ReflejoRetroHook.sol";
import {MsgSenderRouter} from "../test/mocks/MsgSenderRouter.sol";
import {Addresses, IDepositTo} from "./Addresses.sol";
import {PoolSetup} from "./PoolSetup.sol";

/// @notice Retro step 2, Unichain Sepolia: deploy the retro hook next to the v1 pool, on the same token pair, plus a
/// swap router that exposes the account behind each swap so refunds reach it. Needs RETRO_REACTIVE, DEST_TOKEN0 and
/// DEST_TOKEN1. Optional: HOLD_BPS (default 100 = 1%), WINDOW in seconds (default 8), ORIGIN_SKEW_MS (default 0),
/// HOOK_FUNDING in wei (default 0.01 ether).
/// forge script script/06_RetroHookAndPool.s.sol --rpc-url unichain_sepolia --broadcast --account <name> --sender <addr>
contract RetroHookAndPool is PoolSetup {
    using PoolIdLibrary for PoolKey;

    function run() external {
        require(block.chainid == Addresses.UNICHAIN_SEPOLIA, "run on Unichain Sepolia");
        address deployer = _signer();
        Currency c0 = Currency.wrap(vm.envAddress("DEST_TOKEN0"));
        Currency c1 = Currency.wrap(vm.envAddress("DEST_TOKEN1"));

        vm.startBroadcast();
        ReflejoRetroHook hook = ReflejoRetroHook(payable(_deployHook(deployer)));
        IDepositTo(Addresses.UNICHAIN_CALLBACK_PROXY).depositTo{value: vm.envOr("HOOK_FUNDING", uint256(0.01 ether))}(
            address(hook)
        );
        MsgSenderRouter router = new MsgSenderRouter(IPoolManager(Addresses.UNICHAIN_POOL_MANAGER));
        hook.setTrustedRouter(address(router), true);
        MockERC20(Currency.unwrap(c0)).approve(address(router), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(router), type(uint256).max);
        PoolKey memory key = _initWithLiquidity(
            IPoolManager(Addresses.UNICHAIN_POOL_MANAGER),
            PoolModifyLiquidityTest(Addresses.UNICHAIN_MODIFY_LIQUIDITY),
            c0,
            c1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            IHooks(address(hook))
        );
        vm.stopBroadcast();

        console2.log("RETRO_HOOK=%s", address(hook));
        console2.log("DEMO_ROUTER=%s", address(router));
        console2.log("RETRO_POOL_ID=%s", vm.toString(PoolId.unwrap(key.toId())));
    }

    /// @dev Mines a salt for the hook flags and deploys through the CREATE2 deployer with salt ++ init code.
    function _deployHook(address deployer) internal returns (address hook) {
        bytes memory args = _hookArgs(deployer);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes32 salt;
        (hook, salt) = HookMiner.find(Addresses.CREATE2_DEPLOYER, flags, type(ReflejoRetroHook).creationCode, args);
        (bool ok,) = Addresses.CREATE2_DEPLOYER.call(
            abi.encodePacked(salt, type(ReflejoRetroHook).creationCode, args)
        );
        require(ok && hook.code.length > 0, "hook deploy failed");
    }

    function _hookArgs(address deployer) internal view returns (bytes memory) {
        // Same fee settings as the v1 hook, so the two pools differ only in the retroactive surcharge.
        ReflejoHook.FeeConfig memory config =
            ReflejoHook.FeeConfig({baseFee: 3000, captureBps: 6000, maxFee: 30000, maxAge: 120});
        return abi.encode(
            IPoolManager(Addresses.UNICHAIN_POOL_MANAGER),
            Addresses.UNICHAIN_CALLBACK_PROXY,
            vm.envAddress("RETRO_REACTIVE"),
            deployer,
            config,
            uint16(vm.envOr("HOLD_BPS", uint256(100))),
            uint32(vm.envOr("WINDOW", uint256(8))),
            uint32(vm.envOr("ORIGIN_SKEW_MS", uint256(0)))
        );
    }
}
