// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/LocalUSDTEscrow.sol";

/**
 * Deploy LocalUSDTEscrow to Ethereum Mainnet.
 *
 * Usage:
 *   source .env
 *   forge script script/DeployEthereum.s.sol:DeployEthereum \
 *       --rpc-url $ETH_RPC_URL \
 *       --broadcast \
 *       --verify \
 *       --etherscan-api-key $ETHERSCAN_API_KEY
 */
contract DeployEthereum is Script {
    /// @dev USDT on Ethereum Mainnet
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("Deployer:", deployer);
        console.log("Deployer nonce:", vm.getNonce(deployer));
        console.log("USDT:", USDT);

        vm.startBroadcast(deployerKey);
        LocalUSDTEscrow escrow = new LocalUSDTEscrow(USDT);
        vm.stopBroadcast();

        console.log("LocalUSDTEscrow deployed at:", address(escrow));
        console.log("Owner:", escrow.owner());
        console.log("Arbitrator:", escrow.arbitrator());
        console.log("Inviter:", escrow.inviterAddress());
    }
}
