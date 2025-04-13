// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EquityNFT} from "./EquityNFT.sol";
import {IPyth} from "../lib/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "../lib/pyth-sdk-solidity/PythStructs.sol";

interface IEquityNFT {
    function mint(address to, uint256 tokenId, uint256 shares) external;
    function setTokenURI(uint256 tokenId, string memory uri) external;
    function totalShares() external view returns (uint256);
    function getEquityShares(uint256 tokenId) external view returns (uint256);
}

contract BAO is Ownable, ReentrancyGuard {
    using Strings for uint256;
    using SafeERC20 for IERC20;
    
    // Total supply of equity shares
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;
    
    uint256 public totalRaised; // In USD value (18 decimals)
    uint256 public fundraisingGoal; // In USD value (18 decimals)
    bool public fundraisingFinalized;
    bool public goalReached;
    uint256 public fundraisingDeadline;
    uint256 public fundExpiry;
    address public protocolAdmin;
    string public name;
    string public symbol;
    address public contributorNFT;
    uint256 public maxNFTSupply = 10000;
    uint256 public tierDivisor = 1;
    uint256 public minContributionAmount; // In USD value (18 decimals)
    uint256 public totalAdjustedContributions;
    string public baseNFTURI = "https://metadata.baosworld.com/contributor/";
    
    // If maxWhitelistAmount > 0, then its whitelist only. And this is the max amount you can contribute.
    uint256 public maxWhitelistAmount; // In USD value (18 decimals)
    // If maxPublicContributionAmount > 0, then you cannot contribute more than this in public rounds.
    uint256 public maxPublicContributionAmount; // In USD value (18 decimals)
    
    // Pyth Network integration
    IPyth public pythOracle;
    bytes32 public ethUsdPriceId; // Pyth price feed ID for ETH/USD
    uint8 public constant USD_DECIMALS = 18; // Standardize on 18 decimals for USD values
    uint256 public maxConfidenceInterval = 200; // 2% max confidence interval (in basis points)
    uint256 public maxPriceAgeSecs = 300; // Maximum age of price feed data (5 minutes)
    
    // ERC20 token support
    struct TokenConfig {
        bytes32 pythPriceId; // Pyth price feed ID
        bool isEnabled;     // Whether this token is accepted for contributions
    }
    
    mapping(address => TokenConfig) public supportedTokens; // ERC20 token address => TokenConfig
    address[] public supportedTokensList; // List of supported ERC20 tokens

    struct ContributionAmount {
        uint256 amount;      // USD value of contribution (18 decimals)
        uint256 index;       // Index in contributors array
    }
    
    // Token contribution record
    struct TokenContribution {
        address token;      // ETH (address(0)) or ERC20 token address
        uint256 amount;     // Raw token amount with token's native decimals
        uint256 usdValue;   // USD value at time of contribution (18 decimals)
    }
    
    // Contributor records
    mapping(address => ContributionAmount) public contributions;         // Total USD value contributed by address
    mapping(address => TokenContribution[]) public tokenContributions;   // All token contributions by address
    mapping(address => bool) public whitelist;
    address[] public whitelistArray;
    mapping(address => bool) public claimed;
    mapping(address => uint256) public contributorNFTIds;
    mapping(address => uint256) public contributorShares;

    struct Contributor {
        address addr;
        uint256 tierDivisor;
    }

    Contributor[] public contributors;

    event Contribution(address indexed contributor, uint256 usdValue, address tokenAddress, uint256 tokenAmount);
    event FundraisingFinalized(address nftContract);
    event EmergencyEscapeExecuted(address indexed protocolAdmin);
    event NFTMinted(address indexed contributor, uint256 tokenId, uint256 contributionAmount, uint256 shares);
    event Refund(address indexed contributor, address tokenAddress, uint256 tokenAmount);
    event AddWhitelist(address);
    event RemoveWhitelist(address);
    event TierSet(uint256 newTier);
    event MinContributionAmountSet(uint256 amount);
    event TokenAdded(address indexed tokenAddress, bytes32 pythPriceId);
    event TokenRemoved(address indexed tokenAddress);
    event PythOracleSet(address indexed oracleAddress);
    event EthUsdPriceIdSet(bytes32 priceId);

    struct DaoConfig {
        // Basic DAO info
        string name;
        string symbol;
        address daoManager;
        address protocolAdmin;
        // Fundraising parameters
        uint256 fundraisingGoal;
        uint256 fundraisingDeadline;
        uint256 fundExpiry;
        // Contribution limits
        uint256 maxWhitelistAmount;
        uint256 maxPublicContributionAmount;
        uint256 minContributionAmount;
        // NFT config
        string baseNFTURI;
        uint256 maxNFTSupply;
        // Pyth Network config
        address pythOracle;
        bytes32 ethUsdPriceId;
    }

    constructor(DaoConfig memory config) Ownable(config.daoManager) {
        require(config.fundraisingGoal > 0, "Fundraising goal must be greater than 0");
        require(config.fundraisingDeadline > block.timestamp, "_fundraisingDeadline > block.timestamp");
        require(config.fundExpiry > config.fundraisingDeadline, "_fundExpiry > fundraisingDeadline");
        require(config.pythOracle != address(0), "Pyth oracle address cannot be zero");
        require(config.ethUsdPriceId != bytes32(0), "ETH/USD price ID cannot be zero");

        name = config.name;
        symbol = config.symbol;
        protocolAdmin = config.protocolAdmin;
        fundraisingGoal = config.fundraisingGoal;
        fundraisingDeadline = config.fundraisingDeadline;
        fundExpiry = config.fundExpiry;
        maxWhitelistAmount = config.maxWhitelistAmount;
        maxPublicContributionAmount = config.maxPublicContributionAmount;
        minContributionAmount = config.minContributionAmount;
        
        // Set Pyth Network integration
        pythOracle = IPyth(config.pythOracle);
        ethUsdPriceId = config.ethUsdPriceId;
        emit PythOracleSet(config.pythOracle);
        emit EthUsdPriceIdSet(config.ethUsdPriceId);
        
        if (bytes(config.baseNFTURI).length > 0) {
            baseNFTURI = config.baseNFTURI;
        }
        
        if (config.maxNFTSupply > 0) {
            maxNFTSupply = config.maxNFTSupply;
        }
    }

    function contribute() public payable nonReentrant {
        require(!goalReached, "Goal already reached");
        require(block.timestamp < fundraisingDeadline, "Deadline hit");
        require(msg.value > 0, "Contribution must be greater than 0");
        
        // Get ETH/USD price from Pyth
        PythStructs.Price memory ethPrice = pythOracle.getPrice(ethUsdPriceId);
        // Validate the price feed data
        _validatePythPrice(ethPrice, "ETH price feed stale or invalid");
        uint256 ethUsdPrice = _convertPythPriceToUint(ethPrice, USD_DECIMALS);
        
        // Calculate the USD value of the contribution
        uint256 usdValue = (msg.value * ethUsdPrice) / 1 ether;
        
        require(usdValue >= minContributionAmount, "Below minimum contribution");

        // Check whitelist and contribution limits in USD
        if (maxWhitelistAmount > 0) {
            require(whitelist[msg.sender], "You are not whitelisted");
            require(contributions[msg.sender].amount + usdValue <= maxWhitelistAmount, "Exceeding maxWhitelistAmount");
        } else if (maxPublicContributionAmount > 0) {
            require(
                contributions[msg.sender].amount + usdValue <= maxPublicContributionAmount,
                "Exceeding maxPublicContributionAmount"
            );
        }

        uint256 effectiveContribution = msg.value;
        uint256 effectiveUsdValue = usdValue;
        
        // If adding this contribution would exceed the fundraising goal in USD
        if (totalRaised + usdValue > fundraisingGoal) {
            effectiveUsdValue = fundraisingGoal - totalRaised;
            effectiveContribution = (effectiveUsdValue * 1 ether) / ethUsdPrice;
            payable(msg.sender).transfer(msg.value - effectiveContribution);
        }

        // Add or update contributor record
        if (contributions[msg.sender].amount == 0) {
            contributors.push(Contributor(msg.sender, tierDivisor));
            contributions[msg.sender] = ContributionAmount(0, contributors.length - 1);
        } else {
            if (contributors[contributions[msg.sender].index].tierDivisor != tierDivisor) {
                revert("You already contributed in another tier");
            }
        }

        // Store the token contribution
        tokenContributions[msg.sender].push(TokenContribution({
            token: address(0), // ETH is represented by address(0)
            amount: effectiveContribution,
            usdValue: effectiveUsdValue
        }));
        
        // Update totals
        contributions[msg.sender].amount += effectiveUsdValue;
        totalRaised += effectiveUsdValue;

        emit Contribution(msg.sender, effectiveUsdValue, address(0), effectiveContribution);

        if (totalRaised >= fundraisingGoal) {
            goalReached = true;
        }
    }
    
    /**
     * @notice Contribute with an ERC20 token
     * @param token The ERC20 token address to contribute with
     * @param amount The amount of tokens to contribute
     * @param updateData Pyth price feed update data (if needed)
     */
    function contributeWithToken(address token, uint256 amount, bytes[] calldata updateData) external payable nonReentrant {
        // 1. CHECKS: Perform all validations first
        require(!goalReached, "Goal already reached");
        require(block.timestamp < fundraisingDeadline, "Deadline hit");
        require(amount > 0, "Contribution must be greater than 0");
        require(supportedTokens[token].isEnabled, "Token not supported");
        
        // Update price feed if needed (this needs to happen before price check)
        if (updateData.length > 0) {
            uint256 fee = pythOracle.getUpdateFee(updateData);
            require(msg.value >= fee, "Insufficient fee for Pyth price update");
            pythOracle.updatePriceFeeds{value: fee}(updateData);
            
            // Refund excess fee
            if (msg.value > fee) {
                payable(msg.sender).transfer(msg.value - fee);
            }
        }
        
        // Get token price from Pyth
        PythStructs.Price memory tokenPrice = pythOracle.getPrice(supportedTokens[token].pythPriceId);
        // Validate the price feed data
        _validatePythPrice(tokenPrice, "Token price feed stale or invalid");
        uint256 tokenUsdPrice = _convertPythPriceToUint(tokenPrice, USD_DECIMALS);
        
        // Calculate USD value based on token decimals
        uint256 tokenDecimals = 18; // Default for most tokens
        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            tokenDecimals = decimals;
        } catch {
            // Use default 18 decimals if token doesn't implement IERC20Metadata
        }
        
        uint256 usdValue = (amount * tokenUsdPrice) / (10 ** tokenDecimals);
        require(usdValue >= minContributionAmount, "Below minimum contribution");
        
        // Check whitelist and contribution limits in USD
        if (maxWhitelistAmount > 0) {
            require(whitelist[msg.sender], "You are not whitelisted");
            require(contributions[msg.sender].amount + usdValue <= maxWhitelistAmount, "Exceeding maxWhitelistAmount");
        } else if (maxPublicContributionAmount > 0) {
            require(
                contributions[msg.sender].amount + usdValue <= maxPublicContributionAmount,
                "Exceeding maxPublicContributionAmount"
            );
        }
        
        // Calculate effective amounts if we're close to the fundraising goal
        uint256 effectiveAmount = amount;
        uint256 effectiveUsdValue = usdValue;
        
        if (totalRaised + usdValue > fundraisingGoal) {
            effectiveUsdValue = fundraisingGoal - totalRaised;
            effectiveAmount = (effectiveUsdValue * (10 ** tokenDecimals)) / tokenUsdPrice;
        }
        
        // 2. EFFECTS: Update state
        // Add or update contributor record
        if (contributions[msg.sender].amount == 0) {
            contributors.push(Contributor(msg.sender, tierDivisor));
            contributions[msg.sender] = ContributionAmount(0, contributors.length - 1);
        } else {
            if (contributors[contributions[msg.sender].index].tierDivisor != tierDivisor) {
                revert("You already contributed in another tier");
            }
        }
        
        // Store the token contribution
        tokenContributions[msg.sender].push(TokenContribution({
            token: token,
            amount: effectiveAmount,
            usdValue: effectiveUsdValue
        }));
        
        // Update totals
        contributions[msg.sender].amount += effectiveUsdValue;
        totalRaised += effectiveUsdValue;
        
        // 3. INTERACTIONS: External calls
        // Transfer tokens to this contract
        if (effectiveAmount == amount) {
            // Transfer the full amount
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        } else {
            // Transfer only the effective amount if it's less than the full amount
            IERC20(token).safeTransferFrom(msg.sender, address(this), effectiveAmount);
        }
        
        emit Contribution(msg.sender, effectiveUsdValue, token, effectiveAmount);
        
        if (totalRaised >= fundraisingGoal) {
            goalReached = true;
        }
    }

    function addToWhitelist(address[] calldata addresses) external {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        for (uint256 i = 0; i < addresses.length; i++) {
            if (!whitelist[addresses[i]]) {
                whitelist[addresses[i]] = true;
                whitelistArray.push(addresses[i]);
                emit AddWhitelist(addresses[i]);
            }
        }
    }

    function getWhitelistLength() public view returns (uint256) {
        return whitelistArray.length;
    }

    function removeFromWhitelist(address removedAddress) external {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        whitelist[removedAddress] = false;

        for (uint256 i = 0; i < whitelistArray.length; i++) {
            if (whitelistArray[i] == removedAddress) {
                whitelistArray[i] = whitelistArray[whitelistArray.length - 1];
                whitelistArray.pop();
                break;
            }
        }

        emit RemoveWhitelist(removedAddress);
    }

    // Claim NFT function
    function claimNFT() external nonReentrant {
        require(fundraisingFinalized, "fundraising not finalized");
        require(contributorNFT != address(0), "NFT contract not set");
        
        ContributionAmount memory c = contributions[msg.sender];
        require(c.amount > 0, "You did not contribute");
        require(!claimed[msg.sender], "Already claimed");
        
        // Calculate NFT ID based on contributor index
        uint256 tokenId = contributions[msg.sender].index + 1;
        
        // Get contribution and shares
        uint256 contribution = contributions[msg.sender].amount;
        uint256 shares = contributorShares[msg.sender];
        
        // EFFECTS: Update internal state before external calls
        // Mark as claimed first - this prevents reentrancy attacks
        claimed[msg.sender] = true;
        
        // Store the NFT ID for the contributor
        contributorNFTIds[msg.sender] = tokenId;
        
        // Calculate proportion as percentage of total raised (in basis points, 1/100 of a percent)
        uint256 proportion = (contribution * 10000) / totalRaised;
        
        // INTERACTIONS: External calls after state changes
        // Mint NFT to contributor with shares
        IEquityNFT(contributorNFT).mint(msg.sender, tokenId, shares);
        
        // This creates a unique token URI with the contributor's data encoded
        IEquityNFT(contributorNFT).setTokenURI(
            tokenId, 
            string(abi.encodePacked(
                tokenId.toString(), 
                "?contribution=", 
                contribution.toString(),
                "&proportion=",
                proportion.toString(),
                "&shares=",
                shares.toString()
            ))
        );
        
        emit NFTMinted(msg.sender, tokenId, contribution, shares);
    }

    function setMaxWhitelistAmount(uint256 _maxWhitelistAmount) public {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        maxWhitelistAmount = _maxWhitelistAmount;
    }

    function setMaxPublicContributionAmount(uint256 _maxPublicContributionAmount) public {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        maxPublicContributionAmount = _maxPublicContributionAmount;
    }

    // Finalize the fundraising and create NFT contract
    function finalizeFundraising(
        string memory nftName,
        string memory nftSymbol,
        string memory nftBaseURI
    ) external onlyOwner {
        require(goalReached, "Fundraising goal not reached");
        require(!fundraisingFinalized, "Fundraising already finalized");

        // Calculate total adjusted contributions for proportional allocation
        for (uint256 i = 0; i < contributors.length; i++) {
            address contributor = contributors[i].addr;
            uint256 contribution = contributions[contributor].amount;
            totalAdjustedContributions += contribution / contributors[i].tierDivisor;
        }

        // Create NFT contract for contributors with custom name, symbol and URI
        // The DAO manager is set as the owner from the beginning
        EquityNFT nft = new EquityNFT(
            nftName,
            nftSymbol,
            nftBaseURI,
            owner(), // DAO manager is the owner from the beginning
            protocolAdmin
        );
        
        contributorNFT = address(nft);
        
        // Calculate equity shares for each contributor based on their contribution
        for (uint256 i = 0; i < contributors.length; i++) {
            address contributor = contributors[i].addr;
            uint256 contribution = contributions[contributor].amount;
            uint256 adjustedContribution = contribution / contributors[i].tierDivisor;
            
            // Calculate shares proportional to contribution out of MAX_SUPPLY
            uint256 shares = (adjustedContribution * MAX_SUPPLY) / totalAdjustedContributions;
            contributorShares[contributor] = shares;
        }
        
        fundraisingFinalized = true;
        emit FundraisingFinalized(address(nft));
    }

    // Allow contributors to get a refund if the goal is not reached
    function refund() external nonReentrant {
        require(!goalReached, "Fundraising goal was reached");
        require(block.timestamp > fundraisingDeadline, "Deadline not reached yet");
        require(contributions[msg.sender].amount > 0, "No contributions to refund");
        require(!claimed[msg.sender], "Already claimed refund");

        uint256 contributedAmountInUsd = contributions[msg.sender].amount;
        contributions[msg.sender].amount = 0;
        
        // Refund all token contributions
        TokenContribution[] storage tokenContribs = tokenContributions[msg.sender];
        for (uint256 i = 0; i < tokenContribs.length; i++) {
            TokenContribution storage contrib = tokenContribs[i];
            
            if (contrib.token == address(0)) {
                // Refund ETH
                payable(msg.sender).transfer(contrib.amount);
                emit Refund(msg.sender, address(0), contrib.amount);
            } else {
                // Refund ERC20 tokens
                IERC20(contrib.token).safeTransfer(msg.sender, contrib.amount);
                emit Refund(msg.sender, contrib.token, contrib.amount);
            }
        }
        
        claimed[msg.sender] = true;
    }

    // This function is for the DAO manager to execute transactions with the raised funds
    function execute(address[] calldata contracts, bytes[] calldata data, uint256[] calldata msgValues)
        external
        onlyOwner
    {
        require(fundraisingFinalized, "Fundraising not finalized");
        require(contracts.length == data.length && data.length == msgValues.length, "Array lengths mismatch");

        for (uint256 i = 0; i < contracts.length; i++) {
            (bool success,) = contracts[i].call{value: msgValues[i]}(data[i]);
            require(success, "Call failed");
        }
    }

    function extendFundraisingDeadline(uint256 newFundraisingDeadline) external {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        require(!goalReached, "Fundraising goal was reached");
        require(newFundraisingDeadline > fundraisingDeadline, "new fundraising deadline must be > old one");
        fundraisingDeadline = newFundraisingDeadline;
    }

    function emergencyEscape() external {
        require(msg.sender == protocolAdmin, "must be protocol admin");
        require(!fundraisingFinalized, "fundraising already finalized");
        
        // Transfer all native BERA tokens
        (bool success,) = protocolAdmin.call{value: address(this).balance}("");
        require(success, "Native token transfer failed");
        
        // Transfer all supported ERC20 tokens
        for (uint256 i = 0; i < supportedTokensList.length; i++) {
            address token = supportedTokensList[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(token).safeTransfer(protocolAdmin, balance);
            }
        }
        
        emit EmergencyEscapeExecuted(protocolAdmin);
    }

    // Fallback function to make contributions simply by sending ETH to the contract
    receive() external payable {
        if (!goalReached && block.timestamp < fundraisingDeadline) {
            contribute();
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function setTier(uint256 newTierDivisor) external {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        require(newTierDivisor > 0, "Tier divisor must be > 0");
        require(!fundraisingFinalized, "Fundraising already finalized");

        tierDivisor = newTierDivisor;
        emit TierSet(newTierDivisor);
    }
    
    /**
     * @notice Add or update a supported token for fundraising
     * @param tokenAddress The ERC20 token address
     * @param pythPriceId The Pyth price feed ID for this token
     */
    function addSupportedToken(address tokenAddress, bytes32 pythPriceId) external {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        require(tokenAddress != address(0), "Token address cannot be zero");
        require(pythPriceId != bytes32(0), "Price feed ID cannot be zero");
        require(!fundraisingFinalized, "Fundraising already finalized");
        
        // If token not already supported, add to the list
        if (!supportedTokens[tokenAddress].isEnabled) {
            supportedTokensList.push(tokenAddress);
        }
        
        // Set the token config
        supportedTokens[tokenAddress] = TokenConfig({
            pythPriceId: pythPriceId,
            isEnabled: true
        });
        
        emit TokenAdded(tokenAddress, pythPriceId);
    }
    
    /**
     * @notice Remove a token from the supported tokens list
     * @param tokenAddress The ERC20 token address to remove
     */
    function removeSupportedToken(address tokenAddress) external {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        require(!fundraisingFinalized, "Fundraising already finalized");
        require(supportedTokens[tokenAddress].isEnabled, "Token not supported");
        
        // Disable the token
        supportedTokens[tokenAddress].isEnabled = false;
        
        // Remove from the list (maintain order by swapping with last element)
        for (uint256 i = 0; i < supportedTokensList.length; i++) {
            if (supportedTokensList[i] == tokenAddress) {
                supportedTokensList[i] = supportedTokensList[supportedTokensList.length - 1];
                supportedTokensList.pop();
                break;
            }
        }
        
        emit TokenRemoved(tokenAddress);
    }
    
    /**
     * @notice Set the Pyth oracle address
     * @param newPythOracle The new Pyth oracle address
     */
    function setPythOracle(address newPythOracle) external {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        require(newPythOracle != address(0), "Oracle address cannot be zero");
        require(!fundraisingFinalized, "Fundraising already finalized");
        
        pythOracle = IPyth(newPythOracle);
        emit PythOracleSet(newPythOracle);
    }
    
    /**
     * @notice Set the ETH/USD price feed ID
     * @param newPriceId The new ETH/USD price feed ID
     */
    function setEthUsdPriceId(bytes32 newPriceId) external {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        require(newPriceId != bytes32(0), "Price feed ID cannot be zero");
        require(!fundraisingFinalized, "Fundraising already finalized");
        
        ethUsdPriceId = newPriceId;
        emit EthUsdPriceIdSet(newPriceId);
    }
    
    /**
     * @notice Set the maximum allowed confidence interval for price feeds
     * @param newMaxConfidenceInterval The new maximum confidence interval in basis points (e.g., 200 = 2%)
     */
    function setMaxConfidenceInterval(uint256 newMaxConfidenceInterval) external {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        require(newMaxConfidenceInterval > 0, "Confidence interval must be > 0");
        require(!fundraisingFinalized, "Fundraising already finalized");
        
        maxConfidenceInterval = newMaxConfidenceInterval;
    }
    
    /**
     * @notice Record an OTC (over-the-counter) contribution like an NFT that was transferred directly to the DAO manager
     * @dev Only callable by the DAO manager or protocol admin
     * @param contributor The address of the contributor who sent the OTC asset
     * @param usdValue The USD value assigned to the OTC contribution (with 18 decimals)
     * @param description Optional description of the OTC contribution (e.g., "CryptoPunk #1234")
     */
    function recordOtcContribution(address contributor, uint256 usdValue, string calldata description) external {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        require(!fundraisingFinalized, "Fundraising already finalized");
        require(!goalReached, "Goal already reached");
        require(contributor != address(0), "Contributor cannot be zero address");
        require(usdValue > 0, "USD value must be greater than 0");
        require(block.timestamp < fundraisingDeadline, "Fundraising deadline has passed");
        
        uint256 effectiveUsdValue = usdValue;
        
        // If adding this contribution would exceed the fundraising goal in USD
        if (totalRaised + usdValue > fundraisingGoal) {
            effectiveUsdValue = fundraisingGoal - totalRaised;
        }
        
        // Add or update contributor record
        if (contributions[contributor].amount == 0) {
            contributors.push(Contributor(contributor, tierDivisor));
            contributions[contributor] = ContributionAmount(0, contributors.length - 1);
        } else {
            if (contributors[contributions[contributor].index].tierDivisor != tierDivisor) {
                revert("Contributor already contributed in another tier");
            }
        }
        
        // Store the OTC contribution with a special token value (address(1) to distinguish from ETH and regular ERC20s)
        tokenContributions[contributor].push(TokenContribution({
            token: address(1), // Special marker for OTC contributions
            amount: 0,         // No specific token amount since it's an OTC asset
            usdValue: effectiveUsdValue
        }));
        
        // Update totals
        contributions[contributor].amount += effectiveUsdValue;
        totalRaised += effectiveUsdValue;
        
        // Emit a special contribution event with description in the data field
        emit Contribution(contributor, effectiveUsdValue, address(1), 0);
        
        if (totalRaised >= fundraisingGoal) {
            goalReached = true;
        }
    }

    function setMinContributionAmount(uint256 _minContributionAmount) external {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        minContributionAmount = _minContributionAmount;
    }

    function setGoalReached() external {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        goalReached = true;
    }
    
    function setBaseNFTURI(string memory _baseNFTURI) external {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        require(!fundraisingFinalized, "Fundraising already finalized");
        baseNFTURI = _baseNFTURI;
    }
    
    function setMaxNFTSupply(uint256 _maxNFTSupply) external {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        require(!fundraisingFinalized, "Fundraising already finalized");
        require(_maxNFTSupply > 0, "Max NFT supply must be > 0");
        maxNFTSupply = _maxNFTSupply;
    }
    
    // Withdraw funds after fundraising is complete
    function withdraw() external onlyOwner {
        require(fundraisingFinalized, "Fundraising not finalized");
        
        // Transfer all ETH
        payable(owner()).transfer(address(this).balance);
        
        // Transfer all supported ERC20 tokens
        for (uint256 i = 0; i < supportedTokensList.length; i++) {
            address token = supportedTokensList[i];
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(token).safeTransfer(owner(), balance);
            }
        }
    }
    
    // Get total number of equity shares allocated
    function getTotalShares() external view returns (uint256) {
        if (!fundraisingFinalized) return 0;
        return IEquityNFT(contributorNFT).totalShares();
    }
    
    // Get the shares of a specific contributor
    function getContributorShares(address contributor) external view returns (uint256) {
        return contributorShares[contributor];
    }
    
    // Get the percentage of a contributor (with 2 decimal precision - e.g. 12.34% returns as 1234)
    function getContributorPercentage(address contributor) external view returns (uint256) {
        uint256 shares = contributorShares[contributor];
        if (shares == 0 || !fundraisingFinalized) return 0;
        
        uint256 totalShares = IEquityNFT(contributorNFT).totalShares();
        return (shares * 10000) / totalShares;
    }
    
    /**
     * @notice Get all contributors
     * @return Array of contributor addresses
     */
    function getContributors() external view returns (address[] memory) {
        address[] memory result = new address[](contributors.length);
        
        for (uint256 i = 0; i < contributors.length; i++) {
            result[i] = contributors[i].addr;
        }
        
        return result;
    }
    
    /**
     * @notice Get all supported tokens
     * @return Array of token addresses
     */
    function getSupportedTokensList() external view returns (address[] memory) {
        return supportedTokensList;
    }
    
    /**
     * @notice Set the maximum allowed age for price feeds
     * @param newMaxPriceAgeSecs The new maximum price age in seconds
     */
    function setMaxPriceAgeSecs(uint256 newMaxPriceAgeSecs) external {
        require(msg.sender == owner() || msg.sender == protocolAdmin, "Must be owner or protocolAdmin");
        require(newMaxPriceAgeSecs > 0, "Max price age must be > 0");
        require(!fundraisingFinalized, "Fundraising already finalized");
        
        maxPriceAgeSecs = newMaxPriceAgeSecs;
    }

    /**
     * @dev Helper function to validate Pyth price data freshness
     * @param price The Pyth price structure to validate
     * @param errorMessage The error message to revert with if validation fails
     */
    function _validatePythPrice(PythStructs.Price memory price, string memory errorMessage) internal view {
        // 1. Check if the price is too old
        require(
            (block.timestamp - uint256(price.publishTime)) <= maxPriceAgeSecs,
            errorMessage
        );
        
        // 2. Check confidence interval
        // Calculate confidence interval as a percentage of the price
        // price.conf is the absolute confidence value (+/-)
        uint256 confPercent = 0;
        if (price.price > 0) {
            confPercent = (uint256(price.conf) * 10000) / uint256(uint64(price.price));
        }
        
        require(confPercent <= maxConfidenceInterval, "Price confidence interval too large");
    }

    /**
     * @dev Helper function to convert Pyth price to uint256 with desired decimals
     * @param price The Pyth price structure
     * @param targetDecimals The number of decimals desired in the output
     * @return The price as a uint256 with the specified number of decimals
     */
    function _convertPythPriceToUint(PythStructs.Price memory price, uint8 targetDecimals) internal pure returns (uint256) {
        // Pyth prices use negative exponents (e.g., -8 means 10^-8)
        // We need to convert the price to the desired decimal precision
        
        // First, check if the price is negative
        if (price.price < 0) {
            return 0; // Return 0 for negative prices (rare case)
        }
        
        // Calculate the decimal adjustment needed
        int256 priceExpo = int256(price.expo);
        int256 targetExpo = -1 * int256(uint256(targetDecimals));
        int256 expoAdjustment = targetExpo - priceExpo;
        
        uint256 rawPrice = uint256(int256(price.price));
        
        if (expoAdjustment < 0) {
            // Need to multiply the price
            return rawPrice * (10 ** uint256(-1 * expoAdjustment));
        } else if (expoAdjustment > 0) {
            // Need to divide the price
            return rawPrice / (10 ** uint256(expoAdjustment));
        } else {
            // No adjustment needed
            return rawPrice;
        }
    }
}
