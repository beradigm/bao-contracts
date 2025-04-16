// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Script} from "forge-std/Script.sol";
import {BAO} from "../src/BAO.sol";

contract FinalizeFundraising is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address baoAddress = vm.envAddress("BAO_ADDRESS");
        
        // NFT parameters with defaults
        string memory nftName = vm.envOr("NFT_NAME", string("Contributor NFT"));
        string memory nftSymbol = vm.envOr("NFT_SYMBOL", string("CNFT"));
        string memory nftBaseURI = vm.envOr("NFT_BASE_URI", string("https://metadata.baosworld.com/contributor/"));
        
        // Optional: Set goal reached first if needed
        bool setGoalReached = vm.envOr("SET_GOAL_REACHED", false);
        
        // Log configuration
        console.log("Finalizing fundraising for BAO:", baoAddress);
        console.log("NFT Name:", nftName);
        console.log("NFT Symbol:", nftSymbol);
        console.log("NFT Base URI:", nftBaseURI);
        if (setGoalReached) {
            console.log("Will set goal reached before finalizing");
        }
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Get BAO contract
        BAO bao = BAO(baoAddress);
        
        // Set goal reached if requested
        if (setGoalReached) {
            bao.setGoalReached();
            console.log("Goal reached status set");
        }
        
        // Finalize fundraising
        bao.finalizeFundraising(nftName, nftSymbol, nftBaseURI);
        
        // Get the created NFT address
        address nftAddress = bao.contributorNFT();
        
        vm.stopBroadcast();
        
        console.log("Fundraising finalized successfully");
        console.log("EquityNFT deployed to:", nftAddress);
    }
} 