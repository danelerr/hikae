// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {console2} from "forge-std/Script.sol";
import {Signer} from "./Signer.sol";
import {HikaeReactive} from "../src/HikaeReactive.sol";
import {Addresses, IDepositTo} from "./Addresses.sol";

/// @notice Step 4, Reactive Lasna: point the reactive contract at the hook and its pool, and add reserves.
/// Needs REACTIVE, HOOK and DEST_POOL_ID. Optional: RESERVES in wei (default 1 lREACT), and INVERT_TICK=true only
/// if the destination pool lists the pair in the opposite order (scripts 01 and 03 always put hUSD first).
/// The origin clock defaults to Base Sepolia's schedule, checked on 22 Nov 2026 to be exactly 200 ms per block over
/// the previous 5,000,000 blocks. Override with ORIGIN_ANCHOR_BLOCK, ORIGIN_ANCHOR_TIME_MS and ORIGIN_BLOCK_TIME_MS.
/// With PREFIX=RETRO_ it reads RETRO_REACTIVE, RETRO_HOOK and RETRO_POOL_ID instead.
/// forge script script/04_Wire.s.sol --rpc-url lasna --broadcast
contract Wire is Signer {
    function run() external {
        require(block.chainid == Addresses.LASNA, "run on Reactive Lasna");
        _signer();
        string memory prefix = vm.envOr("PREFIX", string(""));
        bool retro = bytes(prefix).length > 0;
        HikaeReactive reactive = HikaeReactive(payable(vm.envAddress(string.concat(prefix, "REACTIVE"))));
        address hook = vm.envAddress(string.concat(prefix, "HOOK"));
        bytes32 destPoolId = vm.envBytes32(retro ? string.concat(prefix, "POOL_ID") : "DEST_POOL_ID");
        uint256 reserves = vm.envOr("RESERVES", uint256(1 ether));
        bool invertTick = vm.envOr("INVERT_TICK", false);
        uint64 anchorBlock = uint64(vm.envOr("ORIGIN_ANCHOR_BLOCK", uint256(62_159_236)));
        uint64 anchorTimeMs = uint64(vm.envOr("ORIGIN_ANCHOR_TIME_MS", uint256(1_795_353_716_000)));
        uint32 blockTimeMs = uint32(vm.envOr("ORIGIN_BLOCK_TIME_MS", uint256(200)));

        vm.startBroadcast();
        reactive.setDestination(hook, destPoolId, invertTick);
        reactive.setOriginClock(anchorBlock, anchorTimeMs, blockTimeMs);
        IDepositTo(Addresses.REACTIVE_SYSTEM).depositTo{value: reserves}(address(reactive));
        vm.stopBroadcast();

        console2.log("wired reactive %s -> hook %s", address(reactive), hook);
    }
}
