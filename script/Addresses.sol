// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Testnet addresses. Uniswap v4: https://docs.uniswap.org/contracts/v4/deployments
/// Reactive: https://dev.reactive.network/origins-and-destinations
library Addresses {
    // Base Sepolia (origin, reference pool)
    uint256 internal constant BASE_SEPOLIA = 84532;
    address internal constant BASE_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant BASE_MODIFY_LIQUIDITY = 0x37429cD17Cb1454C34E7F50b09725202Fd533039;
    address internal constant BASE_SWAP_ROUTER = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9;

    // Unichain Sepolia (destination, protected pool with the hook)
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    address internal constant UNICHAIN_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address internal constant UNICHAIN_MODIFY_LIQUIDITY = 0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB;
    address internal constant UNICHAIN_SWAP_ROUTER = 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4;
    address internal constant UNICHAIN_CALLBACK_PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    // Reactive Lasna
    uint256 internal constant LASNA = 5318007;
    address internal constant REACTIVE_SYSTEM = 0x8888888888888888888888888888888888888888;

    // Foundry's default CREATE2 deployer, used by `new X{salt: s}()` inside scripts
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    int24 internal constant TICK_SPACING = 60;
}

/// @dev Both the Reactive system contract and the callback proxies accept deposits on behalf of a contract.
interface IDepositTo {
    function depositTo(address contract_) external payable;
}
