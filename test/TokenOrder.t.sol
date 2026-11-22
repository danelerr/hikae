// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolSetup} from "../script/PoolSetup.sol";

contract Harness is PoolSetup {
    function deployPair(address owner) external returns (Currency, Currency) {
        vm.startBroadcast(owner);
        (Currency c0, Currency c1) = _deployTokenPair(owner, [address(1), address(2)]);
        vm.stopBroadcast();
        return (c0, c1);
    }
}

contract TokenOrderTest is Test {
    function testFuzz_usdIsAlwaysToken0(uint64 nonce) public {
        nonce = uint64(bound(nonce, 0, 1e9));
        address owner = makeAddr("deployer");
        vm.setNonce(owner, nonce);
        Harness h = new Harness();
        (Currency c0, Currency c1) = h.deployPair(owner);
        assertEq(MockERC20(Currency.unwrap(c0)).symbol(), "rUSD");
        assertEq(MockERC20(Currency.unwrap(c1)).symbol(), "rETH");
        assertLt(uint160(Currency.unwrap(c0)), uint160(Currency.unwrap(c1)));
        assertEq(MockERC20(Currency.unwrap(c0)).balanceOf(owner), 1_000_000 ether);
    }
}
