// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BAO} from "./BAO.sol";
import {BaosDistribution} from "./BaosDistribution.sol";

/**
 * @title BaosFactory
 * @dev Factory contract to deploy BAO instances
 */
contract BaosFactory is Ownable {
    bool public gatedDeployments = true;

    // Protocol admin to be passed to all created DAOs
    address public protocolAdmin;

    event BAOCreated(address indexed nftDao, string name, string symbol);
    event DistributionCreated(address indexed baosContract, address indexed distributionContract);

    constructor(address _protocolAdmin) Ownable(msg.sender) {
        protocolAdmin = _protocolAdmin;
    }

    /**
     * @dev Deploy a new BAO DAO
     * @param config DAO configuration parameters
     * @return Address of the deployed DAO
     */
    function deployDao(BAO.DaoConfig calldata config) external returns (address) {
        if (gatedDeployments) {
            require(msg.sender == owner(), "Not authorized");
        }

        // Ensure protocol admin is set
        BAO.DaoConfig memory updatedConfig = config;
        
        // Always use the factory's protocolAdmin regardless of the input config
        // This ensures the protocol admin cannot be overridden by individual BAO deployments
        updatedConfig.protocolAdmin = protocolAdmin;

        BAO dao = new BAO(updatedConfig);

        emit BAOCreated(address(dao), config.name, config.symbol);
        return address(dao);
    }

    /**
     * @dev Set whether deployments are gated (only owner can deploy)
     * @param _gatedDeployments True if only owner can deploy, false for public deployment
     */
    function setGatedDeployments(bool _gatedDeployments) external onlyOwner {
        gatedDeployments = _gatedDeployments;
    }

    /**
     * @dev Update the protocol admin address
     * @param _protocolAdmin New protocol admin address
     */
    function setProtocolAdmin(address _protocolAdmin) external onlyOwner {
        require(_protocolAdmin != address(0), "Invalid protocol admin address");
        protocolAdmin = _protocolAdmin;
    }
    
    /**
     * @dev Deploy a BaosDistribution contract for a specific EquityNFT
     * @param equityNftAddress Address of the EquityNFT contract to distribute to
     * @return distributionAddress Address of the deployed BaosDistribution contract
     */
    function deployDistribution(address equityNftAddress) external returns (address distributionAddress) {
        // Only protocol admin or factory owner can deploy distributions
        require(msg.sender == protocolAdmin || msg.sender == owner(), "Not authorized");
        require(equityNftAddress != address(0), "Invalid EquityNFT address");
        
        // Deploy a new BaosDistribution contract
        BaosDistribution distribution = new BaosDistribution(equityNftAddress);
        distributionAddress = address(distribution);
        
        emit DistributionCreated(equityNftAddress, distributionAddress);
        
        return distributionAddress;
    }
} 