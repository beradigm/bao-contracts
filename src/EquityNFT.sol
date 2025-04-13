// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title EquityNFT
 * @dev NFT contract for DAO contributors with equity shares tracking and royalty distribution
 */
contract EquityNFT is ERC721URIStorage, ERC2981, Ownable, AccessControl {
    using Strings for uint256;
    using SafeERC20 for IERC20;
    
    // Role definitions
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    
    // Base URI for metadata
    string private _baseTokenURI;
    
    // Image URI for all NFTs in this collection
    string public imageURI;
    
    // Contributor metadata stored on-chain
    struct ContributorMetadata {
        uint256 contribution;  // Amount contributed
        uint256 proportion;    // Proportion of total (in basis points, 10000 = 100%)
        uint256 shares;        // Equity shares
    }
    
    // Mapping for contributor metadata
    mapping(uint256 => ContributorMetadata) public metadata;
    
    // Mapping for equity shares for each NFT
    mapping(uint256 => uint256) public equityShares;
    
    // Total shares issued
    uint256 public totalShares;
    
    // DAO Manager address (owner of the contract)
    address public daoManager;
    
    // Protocol admin for administrative functions
    address public protocolAdmin;
    
    // Royalty fee structure (in basis points, 10000 = 100%)
    uint256 public constant ROYALTY_FEE = 500; // 5% total royalty
    uint256 public constant ADMIN_SHARE = 250; // 2.5% to protocol admin
    uint256 public constant MANAGER_SHARE = 250; // 2.5% to DAO manager
    
    // Accumulated native royalties
    uint256 public pendingRoyalties; // Total native token royalties received
    
    // Events
    event MetadataSet(uint256 tokenId, uint256 contribution, uint256 proportion, uint256 shares);
    event RoyaltyReceived(uint256 amount);
    event RoyaltyClaimed(address indexed recipient, uint256 amount, string role);
    
    /**
     * @dev Constructor
     * @param name Name of the NFT collection
     * @param symbol Symbol of the NFT collection
     * @param baseURI Base URI for NFT metadata
     * @param initialOwner Address of the initial owner (DAO)
     * @param _protocolAdmin Address of the protocol admin
     */
    constructor(
        string memory name, 
        string memory symbol, 
        string memory baseURI, 
        address initialOwner,
        address _protocolAdmin
    ) 
        ERC721(name, symbol)
        Ownable(initialOwner)
    {
        _baseTokenURI = baseURI;
        protocolAdmin = _protocolAdmin;
        daoManager = initialOwner; // DAO Manager is the contract owner
        
        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(MINTER_ROLE, msg.sender); // Grant minter role to deployer (BAO contract)
        
        // Set default royalty info
        _setDefaultRoyalty(address(this), uint96(ROYALTY_FEE));
    }
    
    /**
     * @dev Mint a new NFT with equity shares
     * @param to Recipient address
     * @param tokenId Token ID to mint
     * @param shares Number of equity shares for this NFT
     */
    function mint(address to, uint256 tokenId, uint256 shares) external onlyRole(MINTER_ROLE) {
        _safeMint(to, tokenId);
        equityShares[tokenId] = shares;
        totalShares += shares;
    }
    
    /**
     * @dev Add a new minter that can mint NFTs
     * @param minter Address to grant minter role to
     */
    function addMinter(address minter) external onlyOwner {
        grantRole(MINTER_ROLE, minter);
    }
    
    /**
     * @dev Remove a minter
     * @param minter Address to revoke minter role from
     */
    function removeMinter(address minter) external onlyOwner {
        revokeRole(MINTER_ROLE, minter);
    }
    
    /**
     * @dev Set token URI for a specific token
     * @param tokenId Token ID to set URI for
     * @param uri URI string to set
     */
    function setTokenURI(uint256 tokenId, string memory uri) external onlyRole(MINTER_ROLE) {
        _setTokenURI(tokenId, uri);
    }
    
    /**
     * @dev Set base URI for all tokens
     * @param baseURI New base URI
     */
    function setBaseURI(string memory baseURI) external onlyOwner {
        _baseTokenURI = baseURI;
    }
    
    /**
     * @dev Set image URI for the entire collection
     * @param _imageURI New image URI
     */
    function setImageURI(string memory _imageURI) external onlyOwner {
        imageURI = _imageURI;
    }
    
    /**
     * @dev Set contributor metadata on-chain
     * @param tokenId Token ID
     * @param contribution Amount contributed
     * @param proportion Proportion of total (basis points)
     * @param shares Equity shares
     */
    function setMetadata(
        uint256 tokenId, 
        uint256 contribution, 
        uint256 proportion, 
        uint256 shares
    ) external onlyRole(MINTER_ROLE) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        
        metadata[tokenId] = ContributorMetadata({
            contribution: contribution,
            proportion: proportion,
            shares: shares
        });
        
        emit MetadataSet(tokenId, contribution, proportion, shares);
    }
    
    /**
     * @dev Override _baseURI
     */
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }
    
    /**
     * @dev Override tokenURI to generate dynamic on-chain metadata
     * @param tokenId The token ID to get URI for
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        
        // Check if custom URI was set
        string memory customURI = super.tokenURI(tokenId);
        if (bytes(customURI).length > 0) {
            return customURI;
        }
        
        // Get metadata for this token
        ContributorMetadata memory data = metadata[tokenId];
        
        // Format the proportion as a percentage with 2 decimal places
        string memory proportionStr = _formatBasisPoints(data.proportion);
        
        // Build the JSON metadata
        string memory json = string(abi.encodePacked(
            '{"name": "Contributor #', tokenId.toString(), 
            '", "description": "BAO contributor NFT representing ownership and voting rights.", ',
            '"attributes": [',
                '{"trait_type": "Contribution", "value": "', _formatEther(data.contribution), ' BERA"}, ',
                '{"trait_type": "Equity Share", "value": "', proportionStr, '%"}, ',
                '{"trait_type": "Shares", "value": ', data.shares.toString(), '}',
            ']'
        ));
        
        // Add image if available
        if (bytes(imageURI).length > 0) {
            json = string(abi.encodePacked(json, ', "image": "', imageURI, '"'));
        }
        
        // Close the JSON object
        json = string(abi.encodePacked(json, '}'));
        
        // Return as base64 encoded data URI
        return string(abi.encodePacked(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        ));
    }
    
    /**
     * @dev Helper to format basis points as percentage string
     * @param basisPoints Basis points (10000 = 100%)
     * @return Formatted percentage string
     */
    function _formatBasisPoints(uint256 basisPoints) internal pure returns (string memory) {
        // Convert 10000 basis points to "100.00"
        uint256 whole = basisPoints / 100;
        uint256 fraction = basisPoints % 100;
        
        if (fraction == 0) {
            return string(abi.encodePacked(whole.toString()));
        }
        
        // Add leading zero if needed
        string memory fractionStr = fraction < 10 
            ? string(abi.encodePacked("0", fraction.toString())) 
            : fraction.toString();
        
        return string(abi.encodePacked(whole.toString(), ".", fractionStr));
    }
    
    /**
     * @dev Helper to format wei as ether string
     * @param weiAmount Amount in wei
     * @return Formatted ether amount
     */
    function _formatEther(uint256 weiAmount) internal pure returns (string memory) {
        // Simple implementation - convert to ether by dividing by 10^18
        uint256 ether_value = weiAmount / 1 ether;
        return ether_value.toString();
    }
    
    /**
     * @dev Get equity shares for a token
     * @param tokenId Token ID to query
     * @return Number of equity shares
     */
    function getEquityShares(uint256 tokenId) external view returns (uint256) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        return equityShares[tokenId];
    }
    
    /**
     * @dev Get equity percentage (with 2 decimal precision - e.g. 12.34% returns as 1234)
     * @param tokenId Token ID to query
     * @return Percentage with 2 decimal places (1234 = 12.34%)
     */
    function getEquityPercentage(uint256 tokenId) external view returns (uint256) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        if (totalShares == 0) return 0;
        return (equityShares[tokenId] * 10000) / totalShares;
    }
    
    /**
     * @dev Set new protocol admin
     * @param newProtocolAdmin New protocol admin address
     */
    function setProtocolAdmin(address newProtocolAdmin) external onlyOwner {
        require(newProtocolAdmin != address(0), "Invalid protocol admin");
        protocolAdmin = newProtocolAdmin;
    }
    
    /**
     * @dev Set DAO manager
     * @param newDaoManager New DAO manager address
     */
    function setDaoManager(address newDaoManager) external onlyOwner {
        require(newDaoManager != address(0), "Invalid DAO manager");
        daoManager = newDaoManager;
    }
    
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721URIStorage, ERC2981, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
    
    /**
     * @dev Receive function that handles royalties
     */
    receive() external payable {
        // Track the received royalties
        pendingRoyalties += msg.value;
        
        emit RoyaltyReceived(msg.value);
    }
    
    /**
     * @dev Claim pending royalties in native tokens
     */
    function claimRoyalties() external {
        require(
            msg.sender == protocolAdmin || msg.sender == daoManager,
            "Only protocol admin or DAO manager can claim"
        );
        
        uint256 totalAmount = address(this).balance;
        uint256 claimAmount;
        string memory role;
        
        // Calculate share based on caller
        if (msg.sender == protocolAdmin) {
            claimAmount = (totalAmount * ADMIN_SHARE) / ROYALTY_FEE;
            role = "ProtocolAdmin";
        } else {
            claimAmount = (totalAmount * MANAGER_SHARE) / ROYALTY_FEE;
            role = "DaoManager";
        }
        
        // Transfer royalties
        if (claimAmount > 0) {
            // Native token transfer
            (bool success,) = payable(msg.sender).call{value: claimAmount}("");
            require(success, "Native transfer failed");
            
            emit RoyaltyClaimed(msg.sender, claimAmount, role);
            
            // Update pending royalties
            pendingRoyalties = address(this).balance;
        }
    }
    
    /**
     * @dev Get available royalties for a role in native tokens
     * @param role Address of the role to check
     * @return Amount claimable by the role
     */
    function getAvailableRoyalties(address role) external view returns (uint256) {
        require(
            role == protocolAdmin || role == daoManager,
            "Only protocol admin or DAO manager are eligible"
        );
        
        uint256 totalAmount = address(this).balance;
        
        // Calculate share based on role
        if (role == protocolAdmin) {
            return (totalAmount * ADMIN_SHARE) / ROYALTY_FEE;
        } else {
            return (totalAmount * MANAGER_SHARE) / ROYALTY_FEE;
        }
    }
    
} 