// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {BaosFactory} from "../src/BaosFactory.sol";
import {BAO} from "../src/BAO.sol";
import {MockPyth} from "../lib/pyth-sdk-solidity/MockPyth.sol";
import {PythStructs} from "../lib/pyth-sdk-solidity/PythStructs.sol";

contract BaosFactoryTest is Test {
    // Contracts
    BaosFactory public factory;
    MockPyth public mockPyth;
    
    // Addresses
    address public owner;
    address public protocolAdmin;
    address public user1;
    address public user2;
    address public daoManager;
    
    // Price feed IDs
    bytes32 public beraUsdPriceId;
    
    function setUp() public {
        string memory rpcUrl = vm.envString("BERACHAIN_RPC");
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);
        
        owner = makeAddr("owner");
        protocolAdmin = makeAddr("protocolAdmin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        daoManager = makeAddr("daoManager");
        
        // Set up mock Pyth oracle
        mockPyth = new MockPyth(60, 0); // 60 second validity, no fee
        beraUsdPriceId = bytes32(uint256(1));
        
        // Deploy BaosFactory with the owner as the deployer
        vm.prank(owner);
        factory = new BaosFactory(protocolAdmin);
    }
    
    function test_InitialState() public {
        // Check initial state
        assertEq(factory.owner(), owner);
        assertEq(factory.protocolAdmin(), protocolAdmin);
        assertEq(factory.gatedDeployments(), true);
    }
    
    function test_DeployDao_Owner() public {
        // Prepare DAO configuration
        BAO.DaoConfig memory config = _createDefaultDaoConfig();
        
        // Deploy a DAO as the owner (should succeed)
        vm.prank(owner);
        address daoAddress = factory.deployDao(config);
        
        // Verify the DAO was created
        assertTrue(daoAddress != address(0));
        
        // Verify the DAO state
        BAO dao = BAO(payable(daoAddress));
        assertEq(dao.name(), "Test DAO");
        assertEq(dao.symbol(), "TEST");
        assertEq(dao.owner(), daoManager);
        assertEq(dao.protocolAdmin(), protocolAdmin);
    }
    
    function test_DeployDao_Unauthorized() public {
        // Prepare DAO configuration
        BAO.DaoConfig memory config = _createDefaultDaoConfig();
        
        // Try to deploy a DAO as a non-owner user (should fail)
        vm.prank(user1);
        vm.expectRevert("Not authorized");
        factory.deployDao(config);
    }
    
    function test_DeployDao_Public() public {
        // Set deployments to public
        vm.prank(owner);
        factory.setGatedDeployments(false);
        
        // Prepare DAO configuration
        BAO.DaoConfig memory config = _createDefaultDaoConfig();
        
        // Deploy a DAO as a non-owner user (should succeed now)
        vm.prank(user1);
        address daoAddress = factory.deployDao(config);
        
        // Verify the DAO was created
        assertTrue(daoAddress != address(0));
        
        // Verify the DAO state
        BAO dao = BAO(payable(daoAddress));
        assertEq(dao.name(), "Test DAO");
        assertEq(dao.symbol(), "TEST");
        assertEq(dao.owner(), daoManager);
        assertEq(dao.protocolAdmin(), protocolAdmin);
    }
    
    function test_SetGatedDeployments() public {
        // Verify initial state
        assertEq(factory.gatedDeployments(), true);
        
        // Only owner can change gatedDeployments
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        factory.setGatedDeployments(false);
        
        // Owner can change gatedDeployments
        vm.prank(owner);
        factory.setGatedDeployments(false);
        assertEq(factory.gatedDeployments(), false);
        
        // Owner can change it back
        vm.prank(owner);
        factory.setGatedDeployments(true);
        assertEq(factory.gatedDeployments(), true);
    }
    
    function test_SetProtocolAdmin() public {
        // Verify initial state
        assertEq(factory.protocolAdmin(), protocolAdmin);
        
        // Only owner can change protocolAdmin
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", user1));
        factory.setProtocolAdmin(user2);
        
        // Can't set to zero address
        vm.prank(owner);
        vm.expectRevert("Invalid protocol admin address");
        factory.setProtocolAdmin(address(0));
        
        // Owner can change protocolAdmin
        vm.prank(owner);
        factory.setProtocolAdmin(user2);
        assertEq(factory.protocolAdmin(), user2);
    }
    
    function test_ProtocolAdminInheritance() public {
        // Prepare DAO configuration with zero protocolAdmin
        BAO.DaoConfig memory config = _createDefaultDaoConfig();
        config.protocolAdmin = address(0);
        
        // Deploy a DAO 
        vm.prank(owner);
        address daoAddress = factory.deployDao(config);
        
        // Verify the DAO was created and inherited the factory's protocolAdmin
        BAO dao = BAO(payable(daoAddress));
        assertEq(dao.protocolAdmin(), factory.protocolAdmin());
    }
    
    // Helper function to create a default DAO configuration
    function _createDefaultDaoConfig() internal view returns (BAO.DaoConfig memory) {
        return BAO.DaoConfig({
            name: "Test DAO",
            symbol: "TEST",
            daoManager: daoManager,
            protocolAdmin: protocolAdmin,
            fundraisingGoal: 100_000 * 10**18, // $100K
            fundraisingDeadline: block.timestamp + 30 days,
            fundExpiry: block.timestamp + 60 days,
            maxWhitelistAmount: 0, // No whitelist limit
            maxPublicContributionAmount: 0, // No individual cap
            minContributionAmount: 100 * 10**18, // $100 min contribution
            baseNFTURI: "https://test.uri/",
            maxNFTSupply: 1000,
            pythOracle: address(mockPyth),
            ethUsdPriceId: beraUsdPriceId
        });
    }
}