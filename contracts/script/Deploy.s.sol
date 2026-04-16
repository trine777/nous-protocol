// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/NousCore.sol";

/// @notice Deploy NousCore to Base (Sepolia or mainnet).
contract DeployNous is Script {
    function run() external {
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        vm.startBroadcast();
        NousCore core = new NousCore(treasury);
        console.log("NousCore:", address(core));
        console.log("Treasury:", treasury);
        console.log("Platform fee: 5%");
        vm.stopBroadcast();
    }
}
