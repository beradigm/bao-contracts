// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Script} from "forge-std/Script.sol";
import {BAO} from "../src/BAO.sol";
import {BaosFactory} from "../src/BaosFactory.sol";

contract DeployBao is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        address pythOracleAddress = vm.envAddress("PYTH_ORACLE_ADDRESS");
        bytes32 ethUsdPriceId = vm.envBytes32("ETH_USD_PRICE_ID");
        
        vm.startBroadcast(deployerPrivateKey);
        
        
        BaosFactory factory = BaosFactory(factoryAddress);
        
        
        // placeholder values
        BAO.DaoConfig memory config = BAO.DaoConfig({
            name: "Baos DAO",
            symbol: "BAOS",
            daoManager: vm.addr(deployerPrivateKey),
            protocolAdmin: factory.protocolAdmin(),
            fundraisingGoal: 100 ether,
            fundraisingDeadline: block.timestamp + 30 days,
            fundExpiry: block.timestamp + 60 days,
            maxWhitelistAmount: 10 ether,
            maxPublicContributionAmount: 5 ether,
            minContributionAmount: 0.1 ether,
            baseNFTURI: "https://metadata.baosworld.com/contributor/",
            maxNFTSupply: 10000,
            pythOracle: pythOracleAddress,
            ethUsdPriceId: ethUsdPriceId
        });
        
        // Deploy the DAO
        address daoAddress = factory.deployDao(config);
        
        vm.stopBroadcast();
        
        console.log("BAO DAO deployed to:", daoAddress);
        console.log("DAO name:", config.name);
        console.log("DAO symbol:", config.symbol);
    }
} 