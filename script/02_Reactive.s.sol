// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {console2} from "forge-std/Script.sol";
import {Signer} from "./Signer.sol";
import {ReflejoReactive} from "../src/ReflejoReactive.sol";
import {Addresses} from "./Addresses.sol";

/// @notice Step 2, Reactive Lasna: deploy the contract that watches the Base pool.
/// Needs REF_POOL_ID from step 1. Optional: MIN_TICK_MOVE (default 10), REACTIVE_FUNDING in wei (default 1 lREACT).
/// forge script script/02_Reactive.s.sol --rpc-url lasna --broadcast
contract DeployReactive is Signer {
    function run() external {
        require(block.chainid == Addresses.LASNA, "run on Reactive Lasna");
        _signer();
        bytes32 refPoolId = vm.envBytes32("REF_POOL_ID");
        uint24 minTickMove = uint24(vm.envOr("MIN_TICK_MOVE", uint256(10)));
        uint256 funding = vm.envOr("REACTIVE_FUNDING", uint256(1 ether));

        vm.startBroadcast();
        ReflejoReactive reactive = new ReflejoReactive{value: funding}(
            Addresses.BASE_SEPOLIA, Addresses.BASE_POOL_MANAGER, refPoolId, Addresses.UNICHAIN_SEPOLIA, minTickMove
        );
        vm.stopBroadcast();

        console2.log("REACTIVE=%s", address(reactive));
    }
}
