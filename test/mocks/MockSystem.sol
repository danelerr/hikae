// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Stand-in for the Reactive system contract at 0x8888...8888 in local tests.
/// Stateless on purpose: tests etch its code at the system address and assert on events.
contract MockSystem {
    event Subscribed(
        uint256 chainId, address contractAddress, uint256 topic0, uint256 topic1, uint256 topic2, uint256 topic3
    );
    event CallbackRequested(uint256 chainId, address recipient, uint64 gasLimit, bytes payload);

    function subscribe(uint256 chainId_, address contract_, uint256 topic0_, uint256 topic1_, uint256 topic2_, uint256 topic3_)
        external
    {
        emit Subscribed(chainId_, contract_, topic0_, topic1_, topic2_, topic3_);
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        emit CallbackRequested(config_.chainId, config_.recipient, config_.gasLimit, config_.payload);
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }
}
