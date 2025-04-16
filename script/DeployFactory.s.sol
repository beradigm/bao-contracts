// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Script} from "forge-std/Script.sol";
import {BaosFactory} from "../src/BaosFactory.sol";

contract DeployFactory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address protocolAdmin = vm.envAddress("PROTOCOL_ADMIN");
        
        vm.startBroadcast(deployerPrivateKey);
        
        BaosFactory factory = new BaosFactory(protocolAdmin);
        
        vm.stopBroadcast();
        
        console.log("BaosFactory deployed to:", address(factory));
        console.log("Protocol admin set to:", protocolAdmin);
    }
} 