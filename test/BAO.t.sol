// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {BAO} from "../src/BAO.sol";
import {EquityNFT} from "../src/EquityNFT.sol";
import {BaosFactory} from "../src/BaosFactory.sol";
import {MockPyth} from "../lib/pyth-sdk-solidity/MockPyth.sol";
import {PythStructs} from "../lib/pyth-sdk-solidity/PythStructs.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BAOTest is Test {
    // Contracts
    BaosFactory public factory;
    BAO public bao;
    EquityNFT public nft;
    
    // Addresses
    address public daoManager;
    address public user1;
    address public user2;
    address public user3;
    address public protocolAdmin;
    

    address public ibgtToken = 0xac03CABA51e17c86c921E1f6CBFBdC91F8BB2E6b; 
    address public honeyToken = 0xFCBD14DC51f0A4d49d5E53C2E0950e0bC26d0Dce; 
    
    // Pyth oracle mock
    MockPyth public mockPyth;
    bytes32 public beraUsdPriceId;
    bytes32 public ibgtUsdPriceId;
    bytes32 public honeyUsdPriceId;
    
    int64 public constant BERA_USD_PRICE = 4 * 10**6; // $4 per BERA with 6 decimals (Pyth format)
    int64 public constant IBGT_USD_PRICE = 7 * 10**6; // $7 per iBGT with 6 decimals (Pyth format)
    int64 public constant HONEY_USD_PRICE = 1 * 10**6; // $1 per Honey with 6 decimals (Pyth format)
    int32 public constant EXPO = -6; // 10^-6 precision
    
    function setUp() public {
        string memory rpcUrl = vm.envString("BERACHAIN_RPC");
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        protocolAdmin = makeAddr("protocolAdmin");
        daoManager = makeAddr("daoManager");
        
        // Set up price feed using MockPyth following Pyth documentation
        mockPyth = new MockPyth(60, 0); // 60 second validity, no fee
        beraUsdPriceId = bytes32(uint256(1));
        ibgtUsdPriceId = bytes32(uint256(2));
        honeyUsdPriceId = bytes32(uint256(3));
        
        // Create price update data for 3 tokens
        bytes[] memory updateData = new bytes[](3);
        
        // Set up current BERA price
        PythStructs.Price memory price = PythStructs.Price({
            price: BERA_USD_PRICE,
            conf: uint64(10000),  // Small confidence interval
            expo: EXPO,
            publishTime: uint(block.timestamp)
        });
        
        // Set up EMA price (same as current price for simplicity)
        PythStructs.Price memory emaPrice = PythStructs.Price({
            price: BERA_USD_PRICE,
            conf: uint64(10000),
            expo: EXPO,
            publishTime: uint(block.timestamp)
        });
        
        PythStructs.PriceFeed memory priceFeed = PythStructs.PriceFeed({
            id: beraUsdPriceId,
            price: price,
            emaPrice: emaPrice
        });
        
        updateData[0] = abi.encode(priceFeed);
        
        // Set up iBGT price
        PythStructs.Price memory ibgtPrice = PythStructs.Price({
            price: IBGT_USD_PRICE,
            conf: uint64(10000),  // Small confidence interval
            expo: EXPO,
            publishTime: uint(block.timestamp)
        });
        
        PythStructs.Price memory ibgtEmaPrice = PythStructs.Price({
            price: IBGT_USD_PRICE,
            conf: uint64(10000),
            expo: EXPO,
            publishTime: uint(block.timestamp)
        });
        
        PythStructs.PriceFeed memory ibgtPriceFeed = PythStructs.PriceFeed({
            id: ibgtUsdPriceId,
            price: ibgtPrice,
            emaPrice: ibgtEmaPrice
        });
        
        // Set up Honey price
        PythStructs.Price memory honeyPrice = PythStructs.Price({
            price: HONEY_USD_PRICE,
            conf: uint64(10000),  // Small confidence interval
            expo: EXPO,
            publishTime: uint(block.timestamp)
        });
        
        PythStructs.Price memory honeyEmaPrice = PythStructs.Price({
            price: HONEY_USD_PRICE,
            conf: uint64(10000),
            expo: EXPO,
            publishTime: uint(block.timestamp)
        });
        
        PythStructs.PriceFeed memory honeyPriceFeed = PythStructs.PriceFeed({
            id: honeyUsdPriceId,
            price: honeyPrice,
            emaPrice: honeyEmaPrice
        });
        
        // Set all price feeds
        updateData[1] = abi.encode(ibgtPriceFeed);
        updateData[2] = abi.encode(honeyPriceFeed);
        
        // Update the mock oracle with our price data
        mockPyth.updatePriceFeeds{value: 0}(updateData);
        
        // Set up factory and BAO
        factory = new BaosFactory(protocolAdmin);
        
        // Create the BAO contract
        BAO.DaoConfig memory config = BAO.DaoConfig({
            name: "Steady Teddy Reserve",
            symbol: "STR",
            daoManager: daoManager,
            protocolAdmin: protocolAdmin,
            fundraisingGoal: 250_000 * 10**18, // $250K goal
            fundraisingDeadline: block.timestamp + 30 days,
            fundExpiry: block.timestamp + 60 days,
            maxWhitelistAmount: 1000 * 10**18, // $1000 max whitelist amount
            maxPublicContributionAmount: 0, // No individual cap
            minContributionAmount: 100 * 10**18, // $100 min contribution
            baseNFTURI: "https://test.uri/",
            maxNFTSupply: 1000,
            pythOracle: address(mockPyth),
            ethUsdPriceId: beraUsdPriceId
        });
        
        // Deploy through factory
        address baoAddress = factory.deployDao(config);
        bao = BAO(payable(baoAddress));
    }
    
    function test_DeploymentState() public {
        // Basic contract info
        assertEq(bao.name(), "Steady Teddy Reserve");
        assertEq(bao.symbol(), "STR");
        assertEq(address(bao.owner()), daoManager);
        assertEq(address(bao.protocolAdmin()), protocolAdmin);
        
        // Fundraising parameters
        assertEq(bao.fundraisingGoal(), 250_000 * 10**18);
        assertEq(bao.fundraisingDeadline(), block.timestamp + 30 days);
        assertEq(bao.fundExpiry(), block.timestamp + 60 days);
        assertEq(bao.minContributionAmount(), 100 * 10**18);
        assertEq(bao.maxWhitelistAmount(), 1000 * 10**18);
        assertEq(address(bao.pythOracle()), address(mockPyth));
        assertEq(bao.ethUsdPriceId(), beraUsdPriceId);
    }

    function test_ContributeNativeToken() public {
        // Send 30 BERA from user1 (worth $120 at $4 per BERA)
        address[] memory addresses = new address[](2);
        addresses[0] = user1;
        addresses[1] = user2;

        vm.deal(user1, 35 ether);
        vm.deal(user2, 55 ether);

        vm.prank(daoManager);
        bao.addToWhitelist(addresses);

        vm.prank(user1);
        bao.contribute{value: 30 ether}();
        
        // Verify the contribution was recorded correctly
        (uint256 contributionAmount,) = bao.contributions(user1);
        assertEq(contributionAmount, 120 * 10**18); // $120 in USD value
        assertEq(bao.totalRaised(), 120 * 10**18); // Total raised also $120
        assertEq(address(bao).balance, 30 ether); // 30 BERA in contract
        
        // User2 contributes 50 BERA (worth $200 at $4 per BERA)
        vm.prank(user2);
        bao.contribute{value: 50 ether}();
        
        // Verify total and individual contributions
        (uint256 user1Amount,) = bao.contributions(user1);
        (uint256 user2Amount,) = bao.contributions(user2);
        assertEq(user1Amount, 120 * 10**18); // $120 for user1
        assertEq(user2Amount, 200 * 10**18); // $200 for user2
        assertEq(bao.totalRaised(), 320 * 10**18); // $320 total
        assertEq(address(bao).balance, 80 ether); // 80 BERA total
    }

    function test_ContributeWithIBGT() public {
        vm.prank(daoManager);
        bao.addSupportedToken(ibgtToken, ibgtUsdPriceId);

        // First add users to the whitelist
        address[] memory addresses = new address[](2);
        addresses[0] = user1;
        addresses[1] = user2;
        
        vm.prank(daoManager);
        bao.addToWhitelist(addresses);
        
        // Deal tokens to users for testing if not done already in setUp
        deal(ibgtToken, user1, 1000 * 10**18);
        deal(ibgtToken, user2, 1000 * 10**18);
        
        // User1 approves and contributes 20 iBGT (worth $140 at $7 per iBGT)
        vm.startPrank(user1);
        IERC20(ibgtToken).approve(address(bao), 20 * 10**18);
        
        // Empty update data since we're using the price from setup
        bytes[] memory updateData = new bytes[](0);
        bao.contributeWithToken(ibgtToken, 20 * 10**18, updateData);
        vm.stopPrank();
    
        // Verify the contribution was recorded correctly
        (uint256 contributionAmount,) = bao.contributions(user1);
        assertEq(contributionAmount, 140 * 10**18); // $140 in USD value
        assertEq(bao.totalRaised(), 140 * 10**18); // Total raised also $140
        assertEq(IERC20(ibgtToken).balanceOf(address(bao)), 20 * 10**18); // 20 iBGT in contract
        
        // User2 also contributes with iBGT
        vm.startPrank(user2);
        IERC20(ibgtToken).approve(address(bao), 30 * 10**18);
        bao.contributeWithToken(ibgtToken, 30 * 10**18, updateData);
        vm.stopPrank();
        
        // Verify both contributions
        (uint256 user1Amount,) = bao.contributions(user1);
        (uint256 user2Amount,) = bao.contributions(user2);
        assertEq(user1Amount, 140 * 10**18); // $140 for user1
        assertEq(user2Amount, 210 * 10**18); // $210 for user2 (30 iBGT at $7 each)
        assertEq(bao.totalRaised(), 350 * 10**18); // $350 total
        assertEq(IERC20(ibgtToken).balanceOf(address(bao)), 50 * 10**18); // 50 iBGT total
    }
    
    function test_RecordOtcContribution() public {
        // Record an OTC contribution for user3 worth $5,000
        vm.prank(daoManager);
        bao.recordOtcContribution(user3, 5000 * 10**18, "");
        
        // Verify the contribution was recorded correctly
        (uint256 contributionAmount,) = bao.contributions(user3);
        assertEq(contributionAmount, 5000 * 10**18); // $5,000 in USD value
        assertEq(bao.totalRaised(), 5000 * 10**18); // Total raised is $5,000
        
        // Add another OTC contribution for user4
        address user4 = makeAddr("user4");
        vm.prank(daoManager);
        bao.recordOtcContribution(user4, 3000 * 10**18, "NFT Collection #123");
        
        // Verify total raised and individual contributions
        (uint256 user3Amount,) = bao.contributions(user3);
        (uint256 user4Amount,) = bao.contributions(user4);
        assertEq(user3Amount, 5000 * 10**18); // $5,000 for user3
        assertEq(user4Amount, 3000 * 10**18); // $3,000 for user4
        assertEq(bao.totalRaised(), 8000 * 10**18); // $8,000 total
    }
    
    function test_FinalizeFundraisingAndClaim() public {
        // First enable token contributions
        vm.startPrank(daoManager);
        bao.addSupportedToken(ibgtToken, ibgtUsdPriceId);
        bao.addSupportedToken(honeyToken, honeyUsdPriceId);
        vm.stopPrank();
        
        // Add users to the whitelist
        address[] memory addresses = new address[](3);
        addresses[0] = user1;
        addresses[1] = user2;
        addresses[2] = user3;
        
        vm.prank(daoManager);
        bao.addToWhitelist(addresses);
        
        // User1 contributes in BERA
        vm.deal(user1, 50 ether);
        vm.prank(user1);
        bao.contribute{value: 30 ether}(); // 30 BERA = $120 at $4 per BERA
        
        // User2 contributes in iBGT
        deal(ibgtToken, user2, 100 * 10**18);
        vm.startPrank(user2);
        IERC20(ibgtToken).approve(address(bao), 20 * 10**18);
        bytes[] memory updateData = new bytes[](0);
        bao.contributeWithToken(ibgtToken, 20 * 10**18, updateData); // 20 iBGT = $140 at $7 per iBGT
        vm.stopPrank();
        
        // User3 contributes in Honey
        deal(honeyToken, user3, 150 * 10**18);
        vm.startPrank(user3);
        IERC20(honeyToken).approve(address(bao), 120 * 10**18);
        bao.contributeWithToken(honeyToken, 120 * 10**18, updateData); // 120 Honey = $120 at $1 per Honey
        vm.stopPrank();
        
        // User3 also gets an OTC contribution
        vm.prank(daoManager);
        bao.recordOtcContribution(user3, 50 * 10**18, ""); // $50 OTC contribution
        
        // Verify total raised before finalization
        assertEq(bao.totalRaised(), 430 * 10**18); // $430 total ($120 + $140 + $120 + $50)
        
        // Now finalize the fundraising
        // First set the goal reached state because we didn't hit the goal
        vm.prank(daoManager);
        bao.setGoalReached();
        
        // Then finalize the fundraising with custom NFT name, symbol, and baseURI
        vm.prank(daoManager);
        bao.finalizeFundraising(
            "Bera Reserve Equity", 
            "BREQ", 
            "https://api.bao.fun/nft/metadata/"
        );
        
        // Verify fundraising is finalized
        assertTrue(bao.fundraisingFinalized());
        
        // Have each user claim their NFT
        vm.prank(user1);
        bao.claimNFT();
        
        vm.prank(user2);
        bao.claimNFT();
        
        vm.prank(user3);
        bao.claimNFT();
        
        // Verify NFT claims
        assertTrue(bao.claimed(user1));
        assertTrue(bao.claimed(user2));
        assertTrue(bao.claimed(user3));
        
        // Get NFT contract address
        address nftAddress = bao.contributorNFT();
        assertFalse(nftAddress == address(0));
        
        // Check NFT ownership and share proportions
        EquityNFT equityNft = EquityNFT(payable(nftAddress));
        
        // Get token IDs
        uint256 user1TokenId = bao.contributorNFTIds(user1);
        uint256 user2TokenId = bao.contributorNFTIds(user2);
        uint256 user3TokenId = bao.contributorNFTIds(user3);
        
        // Verify NFT ownership
        assertEq(nft.ownerOf(user1TokenId), user1);
        assertEq(nft.ownerOf(user2TokenId), user2);
        assertEq(nft.ownerOf(user3TokenId), user3);
        
        // Calculate and verify share proportions
        // User1: $120/$430 = 27.9%
        // User2: $140/$430 = 32.6%
        // User3: $170/$430 = 39.5% ($120 Honey + $50 OTC)
        uint256 totalShares = nft.totalShares();
        
        uint256 user1SharePct = nft.getEquityShares(user1TokenId) * 10000 / totalShares;
        uint256 user2SharePct = nft.getEquityShares(user2TokenId) * 10000 / totalShares;
        uint256 user3SharePct = nft.getEquityShares(user3TokenId) * 10000 / totalShares;
        
        // Allow for small rounding errors with approximate equality
        assertApproxEqRel(user1SharePct, 2790, 0.01e18); // ~27.9%
        assertApproxEqRel(user2SharePct, 3260, 0.01e18); // ~32.6%
        assertApproxEqRel(user3SharePct, 3950, 0.01e18); // ~39.5%
    }
    
    function test_EmergencyEscape() public {
        // First enable token support for testing ERC20 escape
        vm.startPrank(daoManager);
        bao.addSupportedToken(ibgtToken, ibgtUsdPriceId);
        bao.addSupportedToken(honeyToken, honeyUsdPriceId);
        
        // Increase the whitelist contribution limit to allow large contributions
        bao.setMaxWhitelistAmount(1_000_000 * 10**18);
        vm.stopPrank();
        
        // Set up users and whitelist them
        address[] memory addresses = new address[](2);
        addresses[0] = user1;
        addresses[1] = user2;
        
        vm.prank(daoManager);
        bao.addToWhitelist(addresses);
        
        // Fund users with BERA and tokens - using smaller amounts to avoid reaching the goal
        vm.deal(user1, 10_000 ether);
        vm.deal(user2, 8_000 ether);
        deal(ibgtToken, user1, 2_000 * 10**18);
        deal(honeyToken, user2, 3_000 * 10**18);
        
        // Check the fundraising goal
        uint256 goal = bao.fundraisingGoal();
        console.log("Fundraising goal (USD): %d", goal / 10**18);
        
        // Make smaller contributions to ensure we don't reach the goal
        // User1 contributes 6k BERA (worth $24k at $4 per BERA)
        vm.startPrank(user1);
        bao.contribute{value: 6_000 ether}();
        IERC20(ibgtToken).approve(address(bao), 1_000 * 10**18);
        bao.contributeWithToken(ibgtToken, 1_000 * 10**18, new bytes[](0)); // Worth $7k at $7 per iBGT
        vm.stopPrank();
        
        // User2 contributes 4k BERA (worth $16k at $4 per BERA)
        vm.startPrank(user2);
        bao.contribute{value: 4_000 ether}();
        IERC20(honeyToken).approve(address(bao), 2_000 * 10**18);
        bao.contributeWithToken(honeyToken, 2_000 * 10**18, new bytes[](0)); // Worth $2k at $1 per Honey
        vm.stopPrank();
        
        // Log total raised to confirm we're below the goal
        console.log("Total raised (USD): %d", bao.totalRaised() / 10**18);
        
        // Verify the contract has received all funds
        assertEq(address(bao).balance, 10_000 ether);
        assertEq(IERC20(ibgtToken).balanceOf(address(bao)), 1_000 * 10**18);
        assertEq(IERC20(honeyToken).balanceOf(address(bao)), 2_000 * 10**18);
        
        // Record protocol admin's initial balances
        uint256 initialBeraBalance = address(protocolAdmin).balance;
        uint256 initialIbgtBalance = IERC20(ibgtToken).balanceOf(protocolAdmin);
        uint256 initialHoneyBalance = IERC20(honeyToken).balanceOf(protocolAdmin);
        
        // Execute emergency escape
        vm.prank(protocolAdmin);
        bao.emergencyEscape();
        
        // Verify protocol admin received all funds
        assertEq(address(bao).balance, 0);
        assertEq(IERC20(ibgtToken).balanceOf(address(bao)), 0);
        assertEq(IERC20(honeyToken).balanceOf(address(bao)), 0);
        
        assertEq(address(protocolAdmin).balance, initialBeraBalance + 10_000 ether);
        assertEq(IERC20(ibgtToken).balanceOf(protocolAdmin), initialIbgtBalance + 1_000 * 10**18);
        assertEq(IERC20(honeyToken).balanceOf(protocolAdmin), initialHoneyBalance + 2_000 * 10**18);
    }
    
    function test_PriceFeedSettings() public {
        // Add supported tokens (iBGT and Honey)
        vm.startPrank(protocolAdmin);
        bao.addSupportedToken(ibgtToken, ibgtUsdPriceId);
        bao.addSupportedToken(honeyToken, honeyUsdPriceId);
        vm.stopPrank();
        
        // 1. Verify default maxPriceAgeSecs is 300 seconds (5 minutes)
        assertEq(bao.maxPriceAgeSecs(), 300);
        
        // 2. Test that only owner or protocol admin can set the max price age
        vm.prank(user1);
        vm.expectRevert("Must be owner or protocolAdmin");
        bao.setMaxPriceAgeSecs(600);
        
        // 3. Test that the protocol admin can set the max price age
        vm.prank(protocolAdmin);
        bao.setMaxPriceAgeSecs(600);
        assertEq(bao.maxPriceAgeSecs(), 600);
        
        // 4. Test that the DAO manager (owner) can set the max price age
        vm.prank(daoManager);
        bao.setMaxPriceAgeSecs(900);
        assertEq(bao.maxPriceAgeSecs(), 900);
        
        // 5. Test that cannot set to zero
        vm.prank(protocolAdmin);
        vm.expectRevert("Max price age must be > 0");
        bao.setMaxPriceAgeSecs(0);
        
        // 6. Verify it can't be changed after fundraising is finalized
        // First set the goal reached state because we didn't hit the goal
        vm.prank(daoManager);
        bao.setGoalReached();
        
        // Then finalize the fundraising
        vm.prank(daoManager);
        bao.finalizeFundraising("Equity NFT", "ENFT", "");
        
        // Try to set the max price age after finalization
        vm.prank(protocolAdmin);
        vm.expectRevert("Fundraising already finalized");
        bao.setMaxPriceAgeSecs(1200);
    }
}
