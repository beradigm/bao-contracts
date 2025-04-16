// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Script} from "forge-std/Script.sol";
import {BAO} from "../src/BAO.sol";
import {BaosFactory} from "../src/BaosFactory.sol";
import {BaosDistribution} from "../src/BaosDistribution.sol";

contract DeployDistribution is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        address baoAddress = vm.envAddress("BAO_ADDRESS");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Get the factory and BAO contract
        BaosFactory factory = BaosFactory(factoryAddress);
        BAO bao = BAO(baoAddress);
        
        // Get equity NFT address from the BAO contract
        address equityNFTAddress = bao.contributorNFT();
        require(equityNFTAddress != address(0), "BAO has no EquityNFT set");
        
        // Deploy distribution contract through factory
        address distributionAddress = factory.deployDistribution(equityNFTAddress);
        
        vm.stopBroadcast();
        
        console.log("BaosDistribution deployed to:", distributionAddress);
        console.log("For EquityNFT:", equityNFTAddress);
    }
} 