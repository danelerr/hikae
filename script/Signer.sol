// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

/// @notice Scripts sign with the account given on the command line, so no private key lives in .env:
/// forge script <script> --rpc-url <chain> --broadcast --account <keystore name> --sender <its address>
abstract contract Signer is Script {
    function _signer() internal view returns (address signer) {
        signer = msg.sender;
        require(signer != DEFAULT_SENDER, "pass --account <keystore name> --sender <its address>");
    }
}
