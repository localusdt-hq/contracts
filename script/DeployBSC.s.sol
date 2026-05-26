// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/LocalUSDTEscrow.sol";

/**
 * Deploy LocalUSDTEscrow to BNB Smart Chain.
 *
 * Usage:
 *   source .env
 *   forge script script/DeployBSC.s.sol:DeployBSC \
 *       --rpc-url $BSC_RPC_URL \
 *       --broadcast \
 *       --verify \
 *       --etherscan-api-key $BSCSCAN_API_KEY \
 *       --verifier-url https://api.bscscan.com/api
 */
contract DeployBSC is Script {
    /// @dev USDT (BSC-USD) on BNB Smart Chain
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;

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
