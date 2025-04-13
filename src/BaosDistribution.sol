// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ContributorNFT Interface
 * @dev Minimal interface for interacting with ContributorNFT contract
 */
interface IContributorNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getEquityShares(uint256 tokenId) external view returns (uint256);
    function totalShares() external view returns (uint256);
}

/**
 * @title EquityNFT Interface
 * @dev Minimal interface for interacting with EquityNFT contract
 */
interface IEquityNFT {
    function contributorNFT() external view returns (address);
    function owner() external view returns (address);
    function contributorNFTIds(address contributor) external view returns (uint256);
}

/**
 * @title BaosDistribution
 * @dev Contract for distributing ETH and ERC20 tokens to ContributorNFT holders
 * proportional to their equity shares
 */
contract BaosDistribution is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // The EquityNFT contract
    IEquityNFT public equityNFT;
    
    // NFT contract address
    IContributorNFT public contributorNFT;
    
    // Mapping from token address to distribution ID to amount
    mapping(address => mapping(uint256 => uint256)) public distributions;
    
    // Current distribution ID for each token
    mapping(address => uint256) public currentDistributionId;
    
    // Total shares at the time of distribution
    mapping(address => mapping(uint256 => uint256)) public totalSharesAtDistribution;
    
    // Max NFT ID to consider when distributing (to avoid unbounded loops)
    uint256 public maxNFTId = 10000;
    
    // Distribution created event
    event DistributionCreated(address indexed token, uint256 indexed distributionId, uint256 amount, uint256 totalShares);
    
    // Distribution sent event
    event DistributionSent(address indexed token, uint256 indexed distributionId, uint256 indexed tokenId, address recipient, uint256 amount);
    
    // Failed distribution event
    event DistributionFailed(address indexed token, uint256 indexed distributionId, uint256 indexed tokenId, address recipient, uint256 amount, string reason);
    
    /**
     * @dev Constructor
     * @param _equityNFT Address of the EquityNFT contract
     */
    constructor(address _equityNFT) Ownable(msg.sender) {
        equityNFT = IEquityNFT(_equityNFT);
        contributorNFT = IContributorNFT(equityNFT.contributorNFT());
        
        // Transfer ownership to the DAO manager
        transferOwnership(equityNFT.owner());
    }
    
    /**
     * @dev Set maximum NFT ID to process in distributions
     * @param _maxNFTId New maximum NFT ID value
     */
    function setMaxNFTId(uint256 _maxNFTId) external onlyOwner {
        require(_maxNFTId > 0, "Max NFT ID must be greater than 0");
        maxNFTId = _maxNFTId;
    }
    
    /**
     * @dev Create a new ETH distribution and automatically distribute to all NFT holders
     */
    function createETHDistribution() external payable onlyOwner {
        require(msg.value > 0, "Must send ETH to distribute");
        
        address ETH_TOKEN = address(0);
        uint256 distributionId = currentDistributionId[ETH_TOKEN] + 1;
        uint256 totalShares = contributorNFT.totalShares();
        
        require(totalShares > 0, "No shares to distribute to");
        
        // Update distribution data
        distributions[ETH_TOKEN][distributionId] = msg.value;
        totalSharesAtDistribution[ETH_TOKEN][distributionId] = totalShares;
        currentDistributionId[ETH_TOKEN] = distributionId;
        
        emit DistributionCreated(ETH_TOKEN, distributionId, msg.value, totalShares);
        
        // Automatically distribute ETH to all NFT holders
        distributeTokens(ETH_TOKEN, distributionId);
    }
    
    /**
     * @dev Create a new ERC20 token distribution and automatically distribute to all NFT holders
     * @param token Address of the ERC20 token to distribute
     * @param amount Amount of tokens to distribute
     */
    function createTokenDistribution(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "Invalid token address");
        require(amount > 0, "Must distribute some tokens");
        
        uint256 distributionId = currentDistributionId[token] + 1;
        uint256 totalShares = contributorNFT.totalShares();
        
        require(totalShares > 0, "No shares to distribute to");
        
        // Transfer tokens from sender to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        // Update distribution data
        distributions[token][distributionId] = amount;
        totalSharesAtDistribution[token][distributionId] = totalShares;
        currentDistributionId[token] = distributionId;
        
        emit DistributionCreated(token, distributionId, amount, totalShares);
        
        // Automatically distribute tokens to all NFT holders
        distributeTokens(token, distributionId);
    }
    
    /**
     * @dev Distribute tokens to all NFT holders for a specific distribution
     * @param token Address of the token to distribute (use address(0) for ETH)
     * @param distributionId ID of the distribution
     */
    function distributeTokens(address token, uint256 distributionId) internal {
        uint256 totalAmount = distributions[token][distributionId];
        uint256 totalShares = totalSharesAtDistribution[token][distributionId];
        uint256 remainingAmount = totalAmount;
        
        // Iterate through all NFTs up to maxNFTId
        for (uint256 tokenId = 1; tokenId <= maxNFTId; tokenId++) {
            try contributorNFT.ownerOf(tokenId) returns (address nftOwner) {
                // NFT exists, calculate token amount
                uint256 tokenShares;
                
                try contributorNFT.getEquityShares(tokenId) returns (uint256 shares) {
                    tokenShares = shares;
                } catch {
                    // Skip if we can't get shares
                    continue; 
                }
                
                uint256 amount = (totalAmount * tokenShares) / totalShares;
                
                if (amount > 0 && amount <= remainingAmount) {
                    remainingAmount -= amount;
                    
                    // Send tokens or ETH to the NFT owner
                    if (token == address(0)) {
                        // ETH distribution
                        (bool success, bytes memory data) = payable(nftOwner).call{value: amount}("");
                        if (success) {
                            emit DistributionSent(token, distributionId, tokenId, nftOwner, amount);
                        } else {
                            // If transfer fails, log it but continue
                            emit DistributionFailed(token, distributionId, tokenId, nftOwner, amount, "ETH transfer failed");
                            remainingAmount += amount; // Add back to remaining amount
                        }
                    } else {
                        // ERC20 token distribution
                        IERC20(token).safeTransfer(nftOwner, amount);
                        emit DistributionSent(token, distributionId, tokenId, nftOwner, amount);
                    }
                }
            } catch {
                // NFT doesn't exist at this ID, continue to next
                continue;
            }
        }
    }
    
    /**
     * @dev Force manual distribution in case automatic distribution had issues
     * @param token Address of the token to distribute (use address(0) for ETH)
     * @param distributionId ID of the distribution
     * @param startTokenId Starting NFT token ID to process
     * @param endTokenId Ending NFT token ID to process (inclusive)
     */
    function manualDistribute(address token, uint256 distributionId, uint256 startTokenId, uint256 endTokenId) external onlyOwner {
        require(distributionId > 0 && distributionId <= currentDistributionId[token], "Invalid distribution ID");
        require(startTokenId <= endTokenId, "Invalid token ID range");
        require(endTokenId <= maxNFTId, "End token ID exceeds maximum");
        
        uint256 totalAmount = distributions[token][distributionId];
        uint256 totalShares = totalSharesAtDistribution[token][distributionId];
        
        for (uint256 tokenId = startTokenId; tokenId <= endTokenId; tokenId++) {
            try contributorNFT.ownerOf(tokenId) returns (address nftOwner) {
                // NFT exists, calculate token amount
                uint256 tokenShares;
                
                try contributorNFT.getEquityShares(tokenId) returns (uint256 shares) {
                    tokenShares = shares;
                } catch {
                    // Skip if we can't get shares
                    continue; 
                }
                
                uint256 amount = (totalAmount * tokenShares) / totalShares;
                
                if (amount > 0) {
                    // Send tokens or ETH to the NFT owner
                    if (token == address(0)) {
                        // ETH distribution
                        (bool success, bytes memory data) = payable(nftOwner).call{value: amount}("");
                        if (success) {
                            emit DistributionSent(token, distributionId, tokenId, nftOwner, amount);
                        } else {
                            emit DistributionFailed(token, distributionId, tokenId, nftOwner, amount, "ETH transfer failed");
                        }
                    } else {
                        // ERC20 token distribution
                        IERC20(token).safeTransfer(nftOwner, amount);
                        emit DistributionSent(token, distributionId, tokenId, nftOwner, amount);
                    }
                }
            } catch {
                // NFT doesn't exist at this ID, continue to next
                continue;
            }
        }
    }
    
    /**
     * @dev Calculate the distribution amount for a specific NFT token
     * @param token Address of the token (use address(0) for ETH)
     * @param distributionId ID of the distribution
     * @param tokenId ID of the NFT token
     * @return Amount to be distributed to the token owner
     */
    function calculateDistributionAmount(address token, uint256 distributionId, uint256 tokenId) external view returns (uint256) {
        if (distributionId == 0 || distributionId > currentDistributionId[token]) {
            return 0;
        }
        
        uint256 totalAmount = distributions[token][distributionId];
        uint256 totalShares = totalSharesAtDistribution[token][distributionId];
        
        try contributorNFT.getEquityShares(tokenId) returns (uint256 tokenShares) {
            return (totalAmount * tokenShares) / totalShares;
        } catch {
            return 0;
        }
    }
    
    /**
     * @dev Get distribution details
     * @param token Address of the token to check (use address(0) for ETH)
     * @param distributionId ID of the distribution to check
     * @return amount Total amount distributed
     * @return totalShares Total shares at the time of distribution
     */
    function getDistributionDetails(address token, uint256 distributionId) 
        external 
        view 
        returns (uint256 amount, uint256 totalShares) 
    {
        amount = distributions[token][distributionId];
        totalShares = totalSharesAtDistribution[token][distributionId];
    }
    
    /**
     * @dev Update the ContributorNFT contract in case it changes
     * @param _contributorNFT New ContributorNFT contract address
     */
    function updateContributorNFT(address _contributorNFT) external onlyOwner {
        contributorNFT = IContributorNFT(_contributorNFT);
    }
    
    /**
     * @dev Get all distributions for a specific token
     * @param token Address of the token (use address(0) for ETH)
     * @return Array of distribution IDs
     */
    function getDistributionIds(address token) external view returns (uint256) {
        return currentDistributionId[token];
    }
    
    // Receive function to allow ETH transfers to the contract
    receive() external payable {
        // Only accept ETH via createETHDistribution function
        require(msg.sender == owner(), "Direct ETH transfers not allowed");
    }
} 