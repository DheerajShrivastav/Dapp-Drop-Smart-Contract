// Filename: script/DeployWeb3Campaigns.s.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Web3Campaigns} from "../src/Web3Campaigns.sol";

// This script is responsible for deploying the Web3Campaigns contract.
contract DeployWeb3Campaigns is Script {
    // The main entry point for the Forge script.
    function run() external {
        // We will start broadcasting from the address provided via the terminal
        // using the --from flag.
        vm.startBroadcast();

        // Deploy the Web3Campaigns contract.
        Web3Campaigns campaigns = new Web3Campaigns();

        // Stop broadcasting.
        vm.stopBroadcast();

        // Log the address of the newly deployed contract.
        console.log("Web3Campaigns deployed to:", address(campaigns));
    }
}
