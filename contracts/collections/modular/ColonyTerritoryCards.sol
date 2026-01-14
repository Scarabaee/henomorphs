// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import {ModularSpecimen} from "../base/ModularSpecimen.sol";
import {ICollectionDiamond} from "../interfaces/ICollectionDiamond.sol";
import {TerritorySVGLib} from "../libraries/TerritorySVGLib.sol";
import {TerritoryMetadataLib} from "../libraries/TerritoryMetadataLib.sol";

/**
 * @title ColonyTerritoryCards
 * @notice Territory NFT Cards dla Colony Wars z on-chain SVG generation
 * @dev Compatible with Colony Wars territory types (1-5)
 *      Uses separate libraries for SVG generation and metadata
 * 
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ColonyTerritoryCards is
    Initializable,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    ERC721BurnableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ModularSpecimen
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant COLONY_WARS_ROLE = keccak256("COLONY_WARS_ROLE");
    bytes32 public constant DIAMOND_ROLE = keccak256("DIAMOND_ROLE");

    enum TerritoryType { ZicoMine, TradeHub, Fortress, Observatory, Sanctuary }
    enum Rarity { COMMON, UNCOMMON, RARE, EPIC, LEGENDARY }
    
    uint256 private constant LEGENDARY_THRESHOLD = 100;
    uint256 private constant EPIC_THRESHOLD = 600;
    uint256 private constant RARE_THRESHOLD = 2100;
    uint256 private constant UNCOMMON_THRESHOLD = 5100;

    struct TerritoryTraits {
        TerritoryType territoryType;
        Rarity rarity;
        uint8 productionBonus;
        uint8 defenseBonus;
        uint8 techLevel;
        uint16 specimenPopulation;
        uint8 colonyWarsType; // 1-5 for Colony Wars compatibility
    }

    mapping(uint256 => TerritoryTraits) private _territoryTraits;
    mapping(uint256 => uint256) private _territoryToColonyId;
    mapping(uint256 => bool) private _territoryActive;
    mapping(uint256 => address) private _approvedTransferTarget;
    
    uint256 private _tokenIdCounter;
    uint256 public maxSupply;
    string private _contractUri;

    mapping(address => uint256) private _walletMintCount;
    uint256 public maxMintsPerWallet;

    event TerritoryMinted(uint256 indexed tokenId, address indexed recipient, TerritoryType territoryType, Rarity rarity);
    event TerritoryAssignedToColony(uint256 indexed tokenId, uint256 indexed colonyId);
    event TerritoryActivated(uint256 indexed tokenId, uint256 indexed colonyId);
    event TerritoryDeactivated(uint256 indexed tokenId, uint256 indexed colonyId);
    event TransferRequested(uint256 indexed tokenId, address indexed from, address indexed to);
    event TransferApproved(uint256 indexed tokenId, address indexed to);
    event TransferRejected(uint256 indexed tokenId, address indexed to, string reason);
    event TerritoryClaimedFromTreasury(uint256 indexed tokenId, address indexed treasury, address indexed recipient);
    event MaxMintsPerWalletUpdated(uint256 newLimit);
    event WalletMintCountReset(address indexed wallet);

    error MaxSupplyReached();
    error InvalidTerritoryType();
    error InvalidRarity();
    error TerritoryAlreadyAssigned();
    error TerritoryNotActive();
    error TransferNotApproved();
    error NotTokenOwner();
    error CannotTransferToZeroAddress();
    error TerritoryNotInTreasury();
    error InvalidTreasuryAddress();
    error AlreadyRevealed();
    error InvalidMaxSupply();
    error MaxMintsPerWalletExceeded();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        string memory name_, 
        string memory symbol_, 
        string memory contractUri_,
        address diamondAddress, 
        uint256 collectionId_, 
        uint256 maxSupply_
    ) public initializer {
        __ERC721_init(name_, symbol_);
        __ERC721Enumerable_init();
        __ERC721Burnable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ModularSpecimen_init(diamondAddress, collectionId_, 1, 1);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(DIAMOND_ROLE, msg.sender);

        maxSupply = maxSupply_;
        _contractUri = contractUri_;
    }

    /**
     * @notice Mint territory with all parameters explicitly provided
     * @dev Main minting function - allows full control over territory attributes
     * @param recipient Address to receive the NFT
     * @param territoryType Type of territory (0-4: ZicoMine, TradeHub, Fortress, Observatory, Sanctuary)
     * @param rarity Rarity level (0-4: Common, Uncommon, Rare, Epic, Legendary)
     * @param productionBonus Production bonus percentage
     * @param defenseBonus Defense bonus percentage
     * @param techLevel Technology level of the territory
     * @param chickenPopulation Number of chickens/specimens in territory
     * @return tokenId Minted token ID
     */
    function mintTerritory(
        address recipient,
        uint8 territoryType,
        uint8 rarity,
        uint16 productionBonus,
        uint16 defenseBonus,
        uint8 techLevel,
        uint16 chickenPopulation
    ) external onlyRole(MINTER_ROLE) nonReentrant returns (uint256 tokenId) {
        if (_tokenIdCounter >= maxSupply) revert MaxSupplyReached();
        if (territoryType == 0 || territoryType > 5) revert InvalidTerritoryType();
        if (rarity > 4) revert InvalidRarity();
        if (maxMintsPerWallet > 0 && _walletMintCount[recipient] >= maxMintsPerWallet) {
            revert MaxMintsPerWalletExceeded();
        }

        tokenId = ++_tokenIdCounter;

        _territoryTraits[tokenId] = TerritoryTraits({
            territoryType: TerritoryType(territoryType - 1),
            rarity: Rarity(rarity),
            productionBonus: uint8(productionBonus),
            defenseBonus: uint8(defenseBonus),
            techLevel: techLevel,
            specimenPopulation: chickenPopulation,
            colonyWarsType: territoryType
        });

        _safeMint(recipient, tokenId);
        _walletMintCount[recipient]++;

        emit TerritoryMinted(tokenId, recipient, TerritoryType(territoryType - 1), Rarity(rarity));
        
        return tokenId;
    }

    /**
     * @notice Mint territory with auto-calculated bonuses (legacy function)
     * @dev Uses predefined formulas to calculate bonuses based on type and rarity
     */
    function mintTerritoryAuto(
        address to, 
        TerritoryType territoryType, 
        Rarity rarity
    ) public onlyRole(MINTER_ROLE) nonReentrant returns (uint256) {
        if (_tokenIdCounter >= maxSupply) revert MaxSupplyReached();
        if (uint8(territoryType) > 5) revert InvalidTerritoryType();
        if (uint8(rarity) > 4) revert InvalidRarity();
        if (maxMintsPerWallet > 0 && _walletMintCount[to] >= maxMintsPerWallet) {
            revert MaxMintsPerWalletExceeded();
        }

        uint256 tokenId = ++_tokenIdCounter;

        _territoryTraits[tokenId] = TerritoryTraits({
            territoryType: territoryType,
            rarity: rarity,
            productionBonus: _calculateBonus(territoryType, rarity),
            defenseBonus: _calculateBonus(territoryType, rarity),
            techLevel: _calculateTechLevel(territoryType, rarity),
            specimenPopulation: _calculatePopulation(territoryType, rarity),
            colonyWarsType: uint8(territoryType)
        });

        _safeMint(to, tokenId);
        _walletMintCount[to]++;

        emit TerritoryMinted(tokenId, to, territoryType, rarity);

        return tokenId;
    }

    /**
     * @notice Mint with randomized rarity
     */
    function mintRandomTerritory(address to, TerritoryType territoryType) public onlyRole(MINTER_ROLE) nonReentrant returns (uint256) {
        if (_tokenIdCounter >= maxSupply) revert MaxSupplyReached();
        if (uint8(territoryType) > 5) revert InvalidTerritoryType();
        if (maxMintsPerWallet > 0 && _walletMintCount[to] >= maxMintsPerWallet) {
            revert MaxMintsPerWalletExceeded();
        }

        _tokenIdCounter++;
        uint256 tokenId = _tokenIdCounter;
        
        uint8 rarity = _calculateRarity(tokenId, territoryType, msg.sender);

        _territoryTraits[tokenId] = TerritoryTraits({
            territoryType: territoryType,
            rarity: Rarity(rarity),
            productionBonus: _calculateBonus(territoryType, Rarity(rarity)),
            defenseBonus: _calculateBonus(territoryType, Rarity(rarity)),
            techLevel: _calculateTechLevel(territoryType, Rarity(rarity)),
            specimenPopulation: _calculatePopulation(territoryType, Rarity(rarity)),
            colonyWarsType: uint8(territoryType) + 1
        });

        _safeMint(to, tokenId);
        _walletMintCount[to]++; 
        emit TerritoryMinted(tokenId, to, territoryType, Rarity(rarity));
        
        return tokenId;
    }

    /**
     * @notice Batch mint territories with auto-calculated bonuses
     * @dev Uses mintTerritoryAuto internally for each territory
     * @param to Address to receive NFTs
     * @param types Array of territory types
     * @param rarities Array of rarities (must match types length)
     * @return tokenIds Array of minted token IDs
     */
    function batchMintTerritories(
        address to, 
        TerritoryType[] calldata types, 
        Rarity[] calldata rarities
    ) external onlyRole(MINTER_ROLE) nonReentrant returns (uint256[] memory) {
        require(types.length == rarities.length, "Length mismatch");
        uint256[] memory tokenIds = new uint256[](types.length);
        
        if (maxMintsPerWallet > 0) {
            uint256 newTotal = _walletMintCount[to] + types.length;
            if (newTotal > maxMintsPerWallet) {
                revert MaxMintsPerWalletExceeded();
            }
        }

        for (uint256 i = 0; i < types.length; i++) {
            tokenIds[i] = mintTerritoryAuto(to, types[i], rarities[i]);
        }
        
        return tokenIds;
    }

    function setMaxSupply(uint256 newMaxSupply) external onlyRole(ADMIN_ROLE) {
        if (newMaxSupply < _tokenIdCounter) revert InvalidMaxSupply();
        maxSupply = newMaxSupply;
    }

    function setMaxMintsPerWallet(uint256 limit) external onlyRole(ADMIN_ROLE) {
        maxMintsPerWallet = limit;
        emit MaxMintsPerWalletUpdated(limit);
    }

    function getWalletMintCount(address wallet) external view returns (uint256) {
        return _walletMintCount[wallet];
    }

    function resetWalletMintCount(address wallet) external onlyRole(ADMIN_ROLE) {
        _walletMintCount[wallet] = 0;
        emit WalletMintCountReset(wallet);
    }

    function batchResetWalletMintCounts(address[] calldata wallets) external onlyRole(ADMIN_ROLE) {
        for (uint256 i = 0; i < wallets.length; i++) {
            _walletMintCount[wallets[i]] = 0;
            emit WalletMintCountReset(wallets[i]);
        }
    }

    /**
     * @notice Assign territory to colony and activate it
     * @dev Called by Colony Wars when player claims territory
     */
    function assignToColony(uint256 tokenId, uint256 colonyId) 
        external 
        onlyRole(COLONY_WARS_ROLE) 
    {
        if (_territoryToColonyId[tokenId] != 0) revert TerritoryAlreadyAssigned();
        
        _territoryToColonyId[tokenId] = colonyId;
        _territoryActive[tokenId] = true;
        
        emit TerritoryAssignedToColony(tokenId, colonyId);
        emit TerritoryActivated(tokenId, colonyId);
    }

    /**
     * @notice Reset colony assignment for a territory card
     * @param tokenId ID of the territory token
     */
    function resetCardAssignment(uint256 tokenId)
        external
        onlyRole(ADMIN_ROLE)
    {
        _resetAssignment(tokenId);
    }

    /**
     * @notice Reset colony assignments for multiple specific territory cards
     * @param tokenIds Array of territory token IDs to reset
     */
    function batchResetCardAssignment(uint256[] calldata tokenIds)
        external
        onlyRole(ADMIN_ROLE)
    {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _resetAssignment(tokenIds[i]);
        }
    }

    /**
     * @notice Reset colony assignments for a range of territory card IDs
     * @param startTokenId First token ID in range (inclusive)
     * @param endTokenId Last token ID in range (inclusive)
     */
    function rangeResetCardAssignment(uint256 startTokenId, uint256 endTokenId)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(startTokenId <= endTokenId, "Invalid range");
        require(endTokenId <= _tokenIdCounter, "End exceeds supply");

        for (uint256 tokenId = startTokenId; tokenId <= endTokenId; tokenId++) {
            // Skip tokens that are not assigned (no error, just skip)
            if (_territoryToColonyId[tokenId] != 0) {
                _resetAssignment(tokenId);
            }
        }
    }

    /**
     * @notice Internal function to reset a single territory assignment
     * @param tokenId ID of the territory token
     */
    function _resetAssignment(uint256 tokenId) internal {
        uint256 colonyId = _territoryToColonyId[tokenId];
        if (colonyId == 0) revert TerritoryAlreadyAssigned();

        _territoryToColonyId[tokenId] = 0;
        _territoryActive[tokenId] = false;

        emit TerritoryDeactivated(tokenId, colonyId);
    }

    /**
     * @notice Deactivate territory (colony destroyed/abandoned)
     * @dev Makes territory transferable again
     */
    function deactivateTerritory(uint256 tokenId) 
        external 
        onlyRole(COLONY_WARS_ROLE) 
    {
        if (!_territoryActive[tokenId]) revert TerritoryNotActive();
        
        uint256 colonyId = _territoryToColonyId[tokenId];
        _territoryActive[tokenId] = false;
        // Keep colonyId for historical tracking 
        emit TerritoryDeactivated(tokenId, colonyId);
    }

    /**
     * @notice Reactivate territory for same colony
     * @dev Useful for seasonal resets without full reassignment
     */
    function reactivateTerritory(uint256 tokenId) 
        external 
        onlyRole(COLONY_WARS_ROLE) 
    {
        if (_territoryToColonyId[tokenId] == 0) revert TerritoryAlreadyAssigned();
        if (_territoryActive[tokenId]) revert TerritoryAlreadyAssigned();
        
        _territoryActive[tokenId] = true;
        emit TerritoryActivated(tokenId, _territoryToColonyId[tokenId]);
    }

    function updatateTerritoryType(uint256 tokenId, uint8 newType) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        if (newType == 0 || newType > 5) revert InvalidTerritoryType();
        _territoryTraits[tokenId].territoryType = TerritoryType(newType - 1);
        _territoryTraits[tokenId].colonyWarsType = newType;
    }

    /**
     * @notice Generate token URI with on-chain SVG and metadata
     * @dev Uses separate libraries for SVG and metadata generation
     */
    function tokenURI(uint256 tokenId) 
        public 
        view 
        override(ERC721Upgradeable) 
        returns (string memory) 
    {
        _requireOwned(tokenId);
        TerritoryTraits memory traits = _territoryTraits[tokenId];
        
        // Convert to library structs
        TerritorySVGLib.TerritoryTraits memory svgTraits = TerritorySVGLib.TerritoryTraits({
            territoryType: TerritorySVGLib.TerritoryType(uint8(traits.territoryType)),
            rarity: TerritorySVGLib.Rarity(uint8(traits.rarity)),
            productionBonus: traits.productionBonus,
            defenseBonus: traits.defenseBonus,
            techLevel: traits.techLevel,
            specimenPopulation: traits.specimenPopulation,
            colonyWarsType: traits.colonyWarsType
        });
        
        TerritoryMetadataLib.TerritoryTraits memory metaTraits = TerritoryMetadataLib.TerritoryTraits({
            territoryType: TerritoryMetadataLib.TerritoryType(uint8(traits.territoryType)),
            rarity: TerritoryMetadataLib.Rarity(uint8(traits.rarity)),
            productionBonus: traits.productionBonus,
            defenseBonus: traits.defenseBonus,
            techLevel: traits.techLevel,
            specimenPopulation: traits.specimenPopulation,
            colonyWarsType: traits.colonyWarsType
        });
        
        // Generate SVG and encode
        string memory svg = TerritorySVGLib.generateSVG(tokenId, svgTraits);
        string memory svgBase64 = Base64.encode(bytes(svg));
        
        // Generate complete token URI
        return TerritoryMetadataLib.generateTokenURI(tokenId, metaTraits, svgBase64);
    }

    function getTerritoryType(uint256 tokenId) external view returns (uint8) {
        _requireOwned(tokenId);
        return uint8(_territoryTraits[tokenId]. colonyWarsType);
    }

    /**
     * @notice OpenSea collection-level metadata
     * @dev Implements contractURI() for OpenSea compatibility
     */
    function contractURI() public view returns (string memory) {
        return _contractUri;
    }

    /**
     * @notice Update collection metadata URI
     * @dev Only admin can update
     */
    function setContractURI(string memory uri) external onlyRole(ADMIN_ROLE) {
        _contractUri = uri;
    }
    
    /**
     * @notice Clear transfer approval
     * @dev Useful for expired approvals or changed conditions
     */
    function clearTransferApproval(uint256 tokenId) 
        external 
        onlyRole(COLONY_WARS_ROLE) 
    {
        delete _approvedTransferTarget[tokenId];
    }

    /**
     * @notice Transfer territory card from treasury to player
     * @dev Only callable by Colony Wars contract after player captures territory
     *      Allows player to claim NFT ownership of their conquered territory
     * @param tokenId Token ID to transfer
     * @param to Recipient address (colony controller)
     */
    function transferFromTreasury(uint256 tokenId, address to) 
        external 
        onlyRole(COLONY_WARS_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert CannotTransferToZeroAddress();
        
        address currentOwner = ownerOf(tokenId);
        
        // This function should only be called when token is in treasury
        // Treasury address should be configured in Colony Wars and passed as validation
        // For now we just check that recipient is not current owner
        if (currentOwner == to) revert InvalidTreasuryAddress();
        
        // Execute transfer - bypasses approval system for treasury claims
        _transfer(currentOwner, to, tokenId);
        
        emit TerritoryClaimedFromTreasury(tokenId, currentOwner, to);
    }

    // View functions
    function getTerritoryTraits(uint256 tokenId) 
        external 
        view 
        returns (TerritoryTraits memory) 
    {
        _requireOwned(tokenId);
        return _territoryTraits[tokenId];
    }

    function getAssignedColony(uint256 tokenId) 
        external 
        view 
        returns (uint256) 
    {
        return _territoryToColonyId[tokenId];
    }

    function isTerritoryActive(uint256 tokenId) 
        external 
        view 
        returns (bool) 
    {
        return _territoryActive[tokenId];
    }

    function getApprovedTransferTarget(uint256 tokenId) 
        external 
        view 
        returns (address) 
    {
        return _approvedTransferTarget[tokenId];
    }

    // Internal calculation helpers (delegate to metadata library)
    function _calculateBonus(TerritoryType tType, Rarity rarity) 
        private 
        pure 
        returns (uint8) 
    {
        return TerritoryMetadataLib.calculateBonus(
            TerritoryMetadataLib.TerritoryType(uint8(tType)),
            TerritoryMetadataLib.Rarity(uint8(rarity))
        );
    }

    function _calculateTechLevel(TerritoryType tType, Rarity rarity) 
        private 
        pure 
        returns (uint8) 
    {
        return TerritoryMetadataLib.calculateTechLevel(
            TerritoryMetadataLib.TerritoryType(uint8(tType)),
            TerritoryMetadataLib.Rarity(uint8(rarity))
        );
    }

    function _calculatePopulation(TerritoryType tType, Rarity rarity) 
        private 
        pure 
        returns (uint16) 
    {
        return TerritoryMetadataLib.calculatePopulation(
            TerritoryMetadataLib.TerritoryType(uint8(tType)),
            TerritoryMetadataLib.Rarity(uint8(rarity))
        );
    }

    // ============ TRANSFER FUNCTIONS (Model D: Conditional Transfer) ============

    /**
     * @notice Request transfer approval from COLONY_WARS_ROLE (for staking)
     * @param tokenId Token to request transfer for
     * @param to Target address for transfer
     */
    function requestTransfer(uint256 tokenId, address to) 
        external 
    {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (to == address(0)) revert CannotTransferToZeroAddress();
        if (!_territoryActive[tokenId]) revert TerritoryNotActive();

        _approvedTransferTarget[tokenId] = to;
        emit TransferRequested(tokenId, msg.sender, to);
    }

    /**
     * @notice Approve transfer (called by MultiCollectionStakingFacet)
     * @param tokenId Token to approve
     * @param to Target address
     */
    function approveTransfer(uint256 tokenId, address to) 
        external 
        onlyRole(COLONY_WARS_ROLE)
    {
        _approvedTransferTarget[tokenId] = to;
        emit TransferApproved(tokenId, to);
    }

    /**
     * @notice Complete transfer after approval
     * @param from Source address
     * @param to Destination address
     * @param tokenId Token to transfer
     */
    function completeTransfer(
        address from,
        address to,
        uint256 tokenId
    ) external onlyRole(COLONY_WARS_ROLE) {
        if (_approvedTransferTarget[tokenId] != to) revert TransferNotApproved();
        
        delete _approvedTransferTarget[tokenId];
        _transfer(from, to, tokenId);
    }

    /**
     * @notice Reject transfer request
     * @param tokenId Token to reject
     * @param reason Rejection reason
     */
    function rejectTransfer(uint256 tokenId, string calldata reason) 
        external 
        onlyRole(COLONY_WARS_ROLE)
    {
        address to = _approvedTransferTarget[tokenId];
        delete _approvedTransferTarget[tokenId];
        emit TransferRejected(tokenId, to, reason);
    }

    // Admin functions
    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    /**
     * @notice Calculate rarity (IDENTICAL to TerritoryManagementFacet)
     */
    function _calculateRarity(
        uint256 tokenId,
        TerritoryType territoryType,
        address minter
    ) internal view returns (uint8) {
        uint256 randomSeed = uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao,
                    tokenId,
                    minter,
                    block.timestamp,
                    territoryType,
                    block.number
                )
            )
        );
        
        uint256 roll = randomSeed % 10000;
        
        if (roll < LEGENDARY_THRESHOLD) return 4;
        if (roll < EPIC_THRESHOLD) return 3;
        if (roll < RARE_THRESHOLD) return 2;
        if (roll < UNCOMMON_THRESHOLD) return 1;
        return 0;
    }

    // UUPS upgrade authorization
    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    // Required overrides
    /**
     * @notice Override transfer logic for conditional transfers
     * @dev Active territories require Colony Wars approval to transfer
     *      Inactive territories transfer freely
     *      Burning (to == address(0)) always allowed
     */
    function _update(address to, uint256 tokenId, address auth)
        internal 
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (address)
    {
        // Allow burning regardless of state
        if (to == address(0)) {
            // Clear approvals on burn
            delete _approvedTransferTarget[tokenId];
            return super._update(to, tokenId, auth);
        }

        // Check if territory is active in colony
        if (_territoryActive[tokenId]) {
            // Require Colony Wars approval for active territories
            if (_approvedTransferTarget[tokenId] != to) {
                revert TransferNotApproved();
            }
            
            // Clear approval after successful use (one-time approval)
            delete _approvedTransferTarget[tokenId];
        }
        
        // Inactive territories transfer freely
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal 
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public 
        view 
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ModularSpecimen overrides
    function _checkDiamondPermission() internal view override {
        _checkRole(DIAMOND_ROLE);
    }

    /**
     * @notice Check if token exists (required by ModularSpecimen)
     * @param tokenId Token ID to check
     * @return Whether token exists
     */
    function _tokenExists(uint256 tokenId) internal view override returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }
}
