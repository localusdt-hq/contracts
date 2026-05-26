// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/LocalUSDTEscrow.sol";

/**
 * Post-deployment: enable the relayer address on a deployed escrow contract.
 *
 * Usage (Ethereum):
 *   source .env
 *   forge script script/ConfigureRelayer.s.sol:ConfigureRelayer \
 *       --rpc-url $ETH_RPC_URL \
 *       --broadcast
 *
 * Usage (BSC):
 *   forge script script/ConfigureRelayer.s.sol:ConfigureRelayer \
 *       --rpc-url $BSC_RPC_URL \
 *       --broadcast
 */
contract ConfigureRelayer is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address escrowAddress = vm.envAddress("ETH_ESCROW_ADDRESS");
        address relayerAddress = vm.envAddress("RELAYER_ADDRESS");

        LocalUSDTEscrow escrow = LocalUSDTEscrow(escrowAddress);

        console.log("Escrow:", escrowAddress);
        console.log("Relayer:", relayerAddress);
        console.log("Currently enabled:", escrow.relayers(relayerAddress));

        vm.startBroadcast(deployerKey);
        escrow.setRelayer(relayerAddress, true);
        vm.stopBroadcast();

        console.log("Relayer enabled:", escrow.relayers(relayerAddress));
    }
}
