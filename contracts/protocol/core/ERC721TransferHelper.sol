// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./MarketplaceRegistry.sol";

/**
 * @title ERC721TransferHelper
 * @notice Handles safe transfers of NFTs with comprehensive validation
 * @dev UUPS upgradeable - Zora-style transfer helper with additional safety checks and batch operations
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ERC721TransferHelper is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using ERC165Checker for address;

    bytes32 public constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // Core dependencies - mutable for upgradeability
    MarketplaceRegistry public registry;

    // Events
    event TransferExecuted(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed from,
        address to,
        bytes32 transferHash
    );
    
    event BatchTransferExecuted(
        address indexed collection,
        uint256[] tokenIds,
        address indexed from,
        address to,
        bytes32 transferHash
    );

    event TransferFailed(
        address indexed collection,
        uint256 indexed tokenId,
        address indexed from,
        address to,
        string reason
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract
     * @param _registry MarketplaceRegistry contract address
     * @param _admin Admin address
     */
    function initialize(address _registry, address _admin) external initializer {
        require(_registry != address(0), "Invalid registry");
        require(_admin != address(0), "Invalid admin");

        __AccessControl_init();
        __UUPSUpgradeable_init();

        registry = MarketplaceRegistry(_registry);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(TRANSFER_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);
    }

    /**
     * @notice Execute a safe NFT transfer with comprehensive validation
     * @param _collection The NFT contract address
     * @param _from The current owner
     * @param _to The new owner
     * @param _tokenId The token ID to transfer
     */
    function safeTransferFrom(
        address _collection,
        address _from,
        address _to,
        uint256 _tokenId
    ) external onlyRole(TRANSFER_ROLE) {
        require(_collection != address(0), "Invalid collection");
        require(_from != address(0), "Invalid from address");
        require(_to != address(0), "Invalid to address");
        require(_from != _to, "Same address transfer");

        _validateAndTransfer(_collection, _from, _to, _tokenId);
    }

    /**
     * @notice Execute batch NFT transfers
     * @param _collection The NFT contract address
     * @param _from The current owner
     * @param _to The new owner
     * @param _tokenIds Array of token IDs to transfer
     */
    function batchTransferFrom(
        address _collection,
        address _from,
        address _to,
        uint256[] calldata _tokenIds
    ) external onlyRole(TRANSFER_ROLE) {
        require(_collection != address(0), "Invalid collection");
        require(_from != address(0), "Invalid from address");
        require(_to != address(0), "Invalid to address");
        require(_from != _to, "Same address transfer");
        require(_tokenIds.length > 0, "Empty token array");
        require(_tokenIds.length <= 100, "Batch too large"); // Gas limit protection

        bytes32 transferHash = keccak256(abi.encodePacked(_collection, _from, _to, _tokenIds, block.timestamp));

        // Validate all tokens first
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            require(_validateOwnership(_collection, _from, _tokenIds[i]), "Invalid ownership");
        }

        // Execute transfers
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            try IERC721(_collection).safeTransferFrom(_from, _to, _tokenIds[i]) {
                // Transfer successful
            } catch Error(string memory reason) {
                emit TransferFailed(_collection, _tokenIds[i], _from, _to, reason);
                revert(string(abi.encodePacked("Transfer failed: ", reason)));
            } catch {
                emit TransferFailed(_collection, _tokenIds[i], _from, _to, "Unknown error");
                revert("Transfer failed: Unknown error");
            }
        }

        emit BatchTransferExecuted(_collection, _tokenIds, _from, _to, transferHash);
    }

    /**
     * @notice Transfer with additional data (for contracts expecting data)
     */
    function safeTransferFromWithData(
        address _collection,
        address _from,
        address _to,
        uint256 _tokenId,
        bytes calldata _data
    ) external onlyRole(TRANSFER_ROLE) {
        require(_collection != address(0), "Invalid collection");
        require(_from != address(0), "Invalid from address");
        require(_to != address(0), "Invalid to address");

        _validateOwnershipAndApproval(_collection, _from, _tokenId);

        bytes32 transferHash = keccak256(abi.encodePacked(_collection, _from, _to, _tokenId, _data, block.timestamp));

        try IERC721(_collection).safeTransferFrom(_from, _to, _tokenId, _data) {
            emit TransferExecuted(_collection, _tokenId, _from, _to, transferHash);
        } catch Error(string memory reason) {
            emit TransferFailed(_collection, _tokenId, _from, _to, reason);
            revert(string(abi.encodePacked("Transfer failed: ", reason)));
        } catch {
            emit TransferFailed(_collection, _tokenId, _from, _to, "Unknown error");
            revert("Transfer failed: Unknown error");
        }
    }

    /**
     * @notice Internal function to validate and execute transfer
     */
    function _validateAndTransfer(
        address _collection,
        address _from,
        address _to,
        uint256 _tokenId
    ) internal {
        _validateOwnershipAndApproval(_collection, _from, _tokenId);

        bytes32 transferHash = keccak256(abi.encodePacked(_collection, _from, _to, _tokenId, block.timestamp));

        try IERC721(_collection).safeTransferFrom(_from, _to, _tokenId) {
            emit TransferExecuted(_collection, _tokenId, _from, _to, transferHash);
        } catch Error(string memory reason) {
            emit TransferFailed(_collection, _tokenId, _from, _to, reason);
            revert(string(abi.encodePacked("Transfer failed: ", reason)));
        } catch {
            emit TransferFailed(_collection, _tokenId, _from, _to, "Unknown error");
            revert("Transfer failed: Unknown error");
        }
    }

    /**
     * @notice Validate ownership and approval before transfer
     */
    function _validateOwnershipAndApproval(
        address _collection,
        address _from,
        uint256 _tokenId
    ) internal view {
        require(_collection.supportsInterface(type(IERC721).interfaceId), "Not ERC721");
        require(_validateOwnership(_collection, _from, _tokenId), "Invalid ownership");
        require(_validateApproval(_collection, _from, _tokenId), "Not approved");
    }

    /**
     * @notice Validate token ownership
     */
    function _validateOwnership(
        address _collection,
        address _expectedOwner,
        uint256 _tokenId
    ) internal view returns (bool) {
        try IERC721(_collection).ownerOf(_tokenId) returns (address owner) {
            return owner == _expectedOwner;
        } catch {
            return false;
        }
    }

    /**
     * @notice Validate transfer approval
     */
    function _validateApproval(
        address _collection,
        address _owner,
        uint256 _tokenId
    ) internal view returns (bool) {
        IERC721 nft = IERC721(_collection);
        
        try nft.getApproved(_tokenId) returns (address approved) {
            if (approved == address(this)) {
                return true;
            }
        } catch {
            // Continue to check isApprovedForAll
        }
        
        try nft.isApprovedForAll(_owner, address(this)) returns (bool approvedForAll) {
            return approvedForAll;
        } catch {
            return false;
        }
    }

    // View functions for validation without state changes
    function validateTransfer(
        address _collection,
        address _from,
        address _to,
        uint256 _tokenId
    ) external view returns (bool isValid, string memory reason) {
        if (_collection == address(0)) return (false, "Invalid collection");
        if (_from == address(0)) return (false, "Invalid from address");
        if (_to == address(0)) return (false, "Invalid to address");
        if (_from == _to) return (false, "Same address transfer");
        
        if (!_collection.supportsInterface(type(IERC721).interfaceId)) {
            return (false, "Not ERC721");
        }
        
        if (!_validateOwnership(_collection, _from, _tokenId)) {
            return (false, "Invalid ownership");
        }
        
        if (!_validateApproval(_collection, _from, _tokenId)) {
            return (false, "Not approved");
        }
        
        return (true, "");
    }

    function validateBatchTransfer(
        address _collection,
        address _from,
        address _to,
        uint256[] calldata _tokenIds
    ) external view returns (bool isValid, string memory reason, uint256 failedIndex) {
        if (_collection == address(0)) return (false, "Invalid collection", 0);
        if (_from == address(0)) return (false, "Invalid from address", 0);
        if (_to == address(0)) return (false, "Invalid to address", 0);
        if (_from == _to) return (false, "Same address transfer", 0);
        if (_tokenIds.length == 0) return (false, "Empty token array", 0);
        if (_tokenIds.length > 100) return (false, "Batch too large", 0);
        
        if (!_collection.supportsInterface(type(IERC721).interfaceId)) {
            return (false, "Not ERC721", 0);
        }
        
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            if (!_validateOwnership(_collection, _from, _tokenIds[i])) {
                return (false, "Invalid ownership", i);
            }
            if (!_validateApproval(_collection, _from, _tokenIds[i])) {
                return (false, "Not approved", i);
            }
        }
        
        return (true, "", 0);
    }

    function isApprovedForTransfer(
        address _collection,
        address _owner,
        uint256 _tokenId
    ) external view returns (bool) {
        return _validateApproval(_collection, _owner, _tokenId);
    }

    /**
     * @notice Update registry address
     */
    function updateRegistry(address _newRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_newRegistry != address(0), "Invalid registry");
        registry = MarketplaceRegistry(_newRegistry);
    }

    /**
     * @notice Get contract version
     */
    function version() external pure returns (string memory) {
        return "1.0.0";
    }

    /**
     * @notice Authorize upgrade - only UPGRADER_ROLE can upgrade
     */
    function _authorizeUpgrade(address newImplementation) 
        internal 
        view
        override 
        onlyRole(UPGRADER_ROLE) 
    {
        require(newImplementation != address(0), "Invalid implementation");
    }
}