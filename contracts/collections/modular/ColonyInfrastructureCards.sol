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
import {ModularSpecimen} from "../../diamonds/modular/base/ModularSpecimen.sol";
import {ICollectionDiamond} from "../../diamonds/modular/interfaces/ICollectionDiamond.sol";
import {InfrastructureSVGLib} from "../../diamonds/modular/libraries/InfrastructureSVGLib.sol";
import {InfrastructureMetadataLib} from "../../diamonds/modular/libraries/InfrastructureMetadataLib.sol";

/**
 * @title ColonyInfrastructureCards
 * @notice Infrastructure/Tools/Defense NFT Cards for Colony Wars
 * @dev RMRK-compatible collection with on-chain SVG generation
 *      Features durability system, repair mechanics, and colony integration
 * 
 * Supply Distribution:
 * - Mining Drills: 1000 (Stone production)
 * - Energy Harvesters: 800 (Energy production)
 * - Processing Plants: 700 (Resource processing)
 * - Defense Turrets: 500 (Territory defense)
 * - Research Labs: 400 (Tech advancement)
 * - Storage Facilities: 600 (Resource capacity)
 * Total: 4000 NFTs
 * 
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ColonyInfrastructureCards is
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
    using InfrastructureSVGLib for InfrastructureSVGLib.InfrastructureTraits;
    using InfrastructureMetadataLib for InfrastructureSVGLib.InfrastructureTraits;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant COLONY_WARS_ROLE = keccak256("COLONY_WARS_ROLE");
    bytes32 public constant DIAMOND_ROLE = keccak256("DIAMOND_ROLE");

    mapping(uint256 => InfrastructureSVGLib.InfrastructureTraits) private _infrastructureTraits;
    mapping(uint256 => uint256) private _equippedToColony;
    mapping(uint256 => bool) private _isEquipped;
    mapping(uint256 => uint256) private _lastUsedTimestamp;
    mapping(uint256 => address) private _approvedTransferTarget;
    
    uint256 private _tokenIdCounter;
    uint256 public maxSupply;
    string private _contractUri;
    
    // Supply limits per type
    mapping(InfrastructureSVGLib.InfrastructureType => uint256) public typeMaxSupply;
    mapping(InfrastructureSVGLib.InfrastructureType => uint256) public typeMinted;

    event InfrastructureMinted(
        uint256 indexed tokenId, 
        address indexed recipient, 
        InfrastructureSVGLib.InfrastructureType infraType, 
        InfrastructureSVGLib.Rarity rarity
    );
    event InfrastructureEquipped(uint256 indexed tokenId, uint256 indexed colonyId);
    event InfrastructureUnequipped(uint256 indexed tokenId, uint256 indexed colonyId);
    event InfrastructureUsed(uint256 indexed tokenId, uint256 indexed colonyId);
    event InfrastructureRepaired(uint256 indexed tokenId, uint8 durabilityRestored, uint256 costPaid);
    event TransferRequested(uint256 indexed tokenId, address indexed from, address indexed to);
    event TransferApproved(uint256 indexed tokenId, address indexed to);
    event TransferRejected(uint256 indexed tokenId, address indexed to, string reason);

    error MaxSupplyReached();
    error TypeMaxSupplyReached();
    error InvalidInfrastructureType();
    error InvalidRarity();
    error InfrastructureAlreadyEquipped();
    error InfrastructureNotEquipped();
    error CannotEquipToZeroColony();
    error InsufficientDurability();
    error TransferNotApproved();
    error NotTokenOwner();
    error CannotTransferWhileEquipped();

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
        
        // Set supply limits per type
        typeMaxSupply[InfrastructureSVGLib.InfrastructureType.MiningDrill] = 1000;
        typeMaxSupply[InfrastructureSVGLib.InfrastructureType.EnergyHarvester] = 800;
        typeMaxSupply[InfrastructureSVGLib.InfrastructureType.ProcessingPlant] = 700;
        typeMaxSupply[InfrastructureSVGLib.InfrastructureType.DefenseTurret] = 500;
        typeMaxSupply[InfrastructureSVGLib.InfrastructureType.ResearchLab] = 400;
        typeMaxSupply[InfrastructureSVGLib.InfrastructureType.StorageFacility] = 600;
    }

    // ============ MINTING FUNCTIONS ============

    function mintInfrastructure(
        address to,
        InfrastructureSVGLib.InfrastructureType infraType,
        InfrastructureSVGLib.Rarity rarity
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256) {
        if (_tokenIdCounter >= maxSupply) revert MaxSupplyReached();
        if (typeMinted[infraType] >= typeMaxSupply[infraType]) revert TypeMaxSupplyReached();
        if (uint8(infraType) > 5) revert InvalidInfrastructureType();
        if (uint8(rarity) > 3) revert InvalidRarity();

        uint256 tokenId = ++_tokenIdCounter;
        typeMinted[infraType]++;

        _infrastructureTraits[tokenId] = InfrastructureSVGLib.InfrastructureTraits({
            infraType: infraType,
            rarity: rarity,
            efficiencyBonus: _calculateEfficiencyBonus(infraType, rarity),
            capacityBonus: _calculateCapacityBonus(infraType, rarity),
            techLevel: _calculateTechLevel(infraType, rarity),
            durability: 100
        });

        _safeMint(to, tokenId);
        emit InfrastructureMinted(tokenId, to, infraType, rarity);
        
        return tokenId;
    }

    function batchMintInfrastructure(
        address to,
        InfrastructureSVGLib.InfrastructureType[] calldata types,
        InfrastructureSVGLib.Rarity[] calldata rarities
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256[] memory) {
        require(types.length == rarities.length, "Length mismatch");
        uint256[] memory tokenIds = new uint256[](types.length);
        
        for (uint256 i = 0; i < types.length; i++) {
            tokenIds[i] = this.mintInfrastructure(to, types[i], rarities[i]);
        }
        
        return tokenIds;
    }

    // ============ COLONY INTEGRATION FUNCTIONS ============

    function equipToColony(uint256 tokenId, uint256 colonyId) 
        external 
        onlyRole(COLONY_WARS_ROLE) 
        nonReentrant 
    {
        if (colonyId == 0) revert CannotEquipToZeroColony();
        if (_isEquipped[tokenId]) revert InfrastructureAlreadyEquipped();
        
        _isEquipped[tokenId] = true;
        _equippedToColony[tokenId] = colonyId;
        
        emit InfrastructureEquipped(tokenId, colonyId);
    }

    function unequipFromColony(uint256 tokenId) 
        external 
        onlyRole(COLONY_WARS_ROLE) 
        nonReentrant 
    {
        if (!_isEquipped[tokenId]) revert InfrastructureNotEquipped();
        
        uint256 colonyId = _equippedToColony[tokenId];
        _isEquipped[tokenId] = false;
        delete _equippedToColony[tokenId];
        
        emit InfrastructureUnequipped(tokenId, colonyId);
    }

    function useInfrastructure(uint256 tokenId) 
        external 
        onlyRole(COLONY_WARS_ROLE) 
        nonReentrant 
        returns (bool) 
    {
        InfrastructureSVGLib.InfrastructureTraits storage traits = _infrastructureTraits[tokenId];
        
        if (traits.durability == 0) revert InsufficientDurability();
        
        // Degrade durability
        uint8 degradation = InfrastructureMetadataLib.calculateDegradation(
            traits.durability,
            traits.rarity
        );
        
        if (traits.durability > degradation) {
            traits.durability -= degradation;
        } else {
            traits.durability = 0;
        }
        
        _lastUsedTimestamp[tokenId] = block.timestamp;
        
        emit InfrastructureUsed(tokenId, _equippedToColony[tokenId]);
        
        return traits.durability > 0;
    }

    function repairInfrastructure(uint256 tokenId, uint8 durabilityToRestore) 
        external 
        onlyRole(COLONY_WARS_ROLE) 
        nonReentrant 
        returns (uint256 cost) 
    {
        InfrastructureSVGLib.InfrastructureTraits storage traits = _infrastructureTraits[tokenId];
        
        require(traits.durability < 100, "Already at full durability");
        require(durabilityToRestore > 0, "Must restore at least 1 durability");
        
        uint8 actualRestore = durabilityToRestore;
        if (traits.durability + actualRestore > 100) {
            actualRestore = 100 - traits.durability;
        }
        
        cost = InfrastructureMetadataLib.calculateRepairCost(actualRestore, traits.rarity);
        traits.durability += actualRestore;
        
        emit InfrastructureRepaired(tokenId, actualRestore, cost);
    }

    // ============ CONDITIONAL TRANSFER (Model D) ============
    function approveTransfer(uint256 tokenId) 
        external 
        onlyRole(COLONY_WARS_ROLE) 
    {
        address approvedTarget = _approvedTransferTarget[tokenId];
        require(approvedTarget != address(0), "No transfer requested");
        
        emit TransferApproved(tokenId, approvedTarget);
    }

    function rejectTransfer(uint256 tokenId, string calldata reason)  
        external 
        onlyRole(COLONY_WARS_ROLE) 
    {
        address approvedTarget = _approvedTransferTarget[tokenId];
        require(approvedTarget != address(0), "No transfer requested");
        
        delete _approvedTransferTarget[tokenId];
        emit TransferRejected(tokenId, approvedTarget, reason);
    }

    function completeTransfer(uint256 tokenId) external nonReentrant {
        address approvedTarget = _approvedTransferTarget[tokenId];
        if (approvedTarget != msg.sender) revert TransferNotApproved();
        
        address from = ownerOf(tokenId);
        delete _approvedTransferTarget[tokenId];
        
        _transfer(from, msg.sender, tokenId);
    }

    // ============ VIEW FUNCTIONS ============

    function tokenURI(uint256 tokenId) 
        public 
        view 
        override 
        returns (string memory) 
    {
        _requireOwned(tokenId);
        return InfrastructureMetadataLib.generateTokenURI(
            tokenId,
            _infrastructureTraits[tokenId]
        );
    }

    function contractURI() public view returns (string memory) {
        return _contractUri;
    }

    function getTraits(uint256 tokenId) 
        external 
        view 
        returns (InfrastructureSVGLib.InfrastructureTraits memory) 
    {
        _requireOwned(tokenId);
        return _infrastructureTraits[tokenId];
    }

    function getEquippedColony(uint256 tokenId) external view returns (uint256) {
        return _equippedToColony[tokenId];
    }

    function isEquipped(uint256 tokenId) external view returns (bool) {
        return _isEquipped[tokenId];
    }

    function getTotalEfficiency(uint256 tokenId) external view returns (uint256) {
        InfrastructureSVGLib.InfrastructureTraits memory traits = _infrastructureTraits[tokenId];
        return InfrastructureMetadataLib.calculateTotalEfficiency(
            traits.efficiencyBonus,
            traits.rarity
        );
    }

    function getRepairCost(uint256 tokenId) external view returns (uint256) {
        InfrastructureSVGLib.InfrastructureTraits memory traits = _infrastructureTraits[tokenId];
        uint8 durabilityLost = 100 - traits.durability;
        return InfrastructureMetadataLib.calculateRepairCost(durabilityLost, traits.rarity);
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
        if (_isEquipped[tokenId]) revert CannotTransferWhileEquipped();
        
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
        if (_approvedTransferTarget[tokenId] != to) revert TransferNotApproved();
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
        if (_isEquipped[tokenId]) revert CannotTransferWhileEquipped();
        
        delete _approvedTransferTarget[tokenId];
        _transfer(from, to, tokenId);
    }

    // ============ ADMIN FUNCTIONS ============

    function setContractURI(string memory newContractUri) 
        external 
        onlyRole(ADMIN_ROLE) 
    {
        _contractUri = newContractUri;
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function updateTypeMaxSupply(
        InfrastructureSVGLib.InfrastructureType infraType,
        uint256 newMax
    ) external onlyRole(ADMIN_ROLE) {
        require(newMax >= typeMinted[infraType], "Cannot set below minted");
        typeMaxSupply[infraType] = newMax;
    }

    // ============ INTERNAL FUNCTIONS ============

    function _calculateEfficiencyBonus(
        InfrastructureSVGLib.InfrastructureType infraType,
        InfrastructureSVGLib.Rarity rarity
    ) private pure returns (uint8) {
        uint8 baseBonus = infraType == InfrastructureSVGLib.InfrastructureType.MiningDrill ? 20 :
                         infraType == InfrastructureSVGLib.InfrastructureType.EnergyHarvester ? 25 :
                         infraType == InfrastructureSVGLib.InfrastructureType.ProcessingPlant ? 30 : 15;
        
        if (rarity == InfrastructureSVGLib.Rarity.Legendary) return baseBonus + 20;
        if (rarity == InfrastructureSVGLib.Rarity.Epic) return baseBonus + 15;
        if (rarity == InfrastructureSVGLib.Rarity.Rare) return baseBonus + 10;
        return baseBonus;
    }

    function _calculateCapacityBonus(
        InfrastructureSVGLib.InfrastructureType infraType,
        InfrastructureSVGLib.Rarity rarity
    ) private pure returns (uint8) {
        uint8 baseCapacity = infraType == InfrastructureSVGLib.InfrastructureType.StorageFacility ? 50 :
                            infraType == InfrastructureSVGLib.InfrastructureType.DefenseTurret ? 30 : 20;
        
        if (rarity == InfrastructureSVGLib.Rarity.Legendary) return baseCapacity + 30;
        if (rarity == InfrastructureSVGLib.Rarity.Epic) return baseCapacity + 20;
        if (rarity == InfrastructureSVGLib.Rarity.Rare) return baseCapacity + 10;
        return baseCapacity;
    }

    function _calculateTechLevel(
        InfrastructureSVGLib.InfrastructureType infraType,
        InfrastructureSVGLib.Rarity rarity
    ) private pure returns (uint8) {
        uint8 baseTech = infraType == InfrastructureSVGLib.InfrastructureType.ResearchLab ? 5 :
                        infraType == InfrastructureSVGLib.InfrastructureType.DefenseTurret ? 4 : 3;
        
        return baseTech + uint8(rarity);
    }

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

    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(ADMIN_ROLE) 
    {}

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721Upgradeable, ERC721EnumerableUpgradeable) returns (address) {
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
        override(
            ERC721Upgradeable,
            ERC721EnumerableUpgradeable,
            AccessControlUpgradeable
        )
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
