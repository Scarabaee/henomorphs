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
import {ResourceSVGLib} from "../../diamonds/modular/libraries/ResourceSVGLib.sol";
import {IResourceDescriptor} from "./interfaces/IResourceDescriptor.sol";

/**
 * @title ColonyResourceCards
 * @notice Resource NFT Cards for Colony Wars economy
 * @dev UUPS upgradeable ERC721 with on-chain SVG generation
 *
 * Resource Types:
 * - BasicMaterials: 2000 supply (Stone, Wood)
 * - EnergyCrystals: 1500 supply (Energy)
 * - BioCompounds: 1200 supply (Biological)
 * - RareElements: 800 supply (Rare minerals)
 * Total: 5500 NFTs
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract ColonyResourceCards is
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

    // Rarity thresholds (out of 10000) - matching ColonyTerritoryCards
    uint256 private constant LEGENDARY_THRESHOLD = 100;   // 1%
    uint256 private constant EPIC_THRESHOLD = 600;        // 5%
    uint256 private constant RARE_THRESHOLD = 2100;       // 15%
    uint256 private constant UNCOMMON_THRESHOLD = 5100;   // 30%
    // Common = remaining 49%

    mapping(uint256 => ResourceSVGLib.ResourceTraits) private _resourceTraits;
    mapping(uint256 => uint256) private _stakedToNode;
    mapping(uint256 => bool) private _isStaked;
    mapping(uint256 => address) private _approvedTransferTarget;
    mapping(address => uint256) private _walletMintCount;

    uint256 private _tokenIdCounter;

    /// @notice External metadata renderer contract for tokenURI/SVG generation
    IResourceDescriptor public metadataRenderer;

    /// @notice Maximum total supply
    uint256 public maxSupply;

    /// @notice Maximum mints per wallet
    uint256 public maxMintsPerWallet;

    // Supply limits per type
    mapping(ResourceSVGLib.ResourceType => uint256) public typeMaxSupply;
    mapping(ResourceSVGLib.ResourceType => uint256) public typeMinted;

    event ResourceMinted(
        uint256 indexed tokenId,
        address indexed recipient,
        ResourceSVGLib.ResourceType resourceType,
        ResourceSVGLib.Rarity rarity
    );
    event ResourceStaked(uint256 indexed tokenId, uint256 indexed nodeId);
    event ResourceUnstaked(uint256 indexed tokenId, uint256 indexed nodeId);
    event ResourcesCombined(uint256[] burnedTokens, uint256 indexed newTokenId);
    event TransferRequested(uint256 indexed tokenId, address indexed from, address indexed to);
    event TransferApproved(uint256 indexed tokenId, address indexed to);
    event MetadataRendererUpdated(address indexed oldRenderer, address indexed newRenderer);

    error MaxSupplyReached();
    error TypeMaxSupplyReached();
    error InvalidResourceType();
    error InvalidRarity();
    error ResourceAlreadyStaked();
    error ResourceNotStaked();
    error TransferNotApproved();
    error NotTokenOwner();
    error CannotTransferWhileStaked();
    error InvalidCombineInput();
    error InvalidMetadataRenderer();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(
        string memory name_,
        string memory symbol_,
        address diamondAddress,
        uint256 collectionId_,
        IResourceDescriptor _metadataRenderer,
        uint256 _maxSupply,
        uint256 _maxMintsPerWallet
    ) public initializer {
        if (address(_metadataRenderer) == address(0)) revert InvalidMetadataRenderer();

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

        metadataRenderer = _metadataRenderer;
        maxSupply = _maxSupply;
        maxMintsPerWallet = _maxMintsPerWallet;

        // Set supply limits per type
        typeMaxSupply[ResourceSVGLib.ResourceType.BasicMaterials] = 2000;
        typeMaxSupply[ResourceSVGLib.ResourceType.EnergyCrystals] = 1500;
        typeMaxSupply[ResourceSVGLib.ResourceType.BioCompounds] = 1200;
        typeMaxSupply[ResourceSVGLib.ResourceType.RareElements] = 800;
    }

    // ============ MINTING FUNCTIONS ============

    function mintResource(
        address to,
        ResourceSVGLib.ResourceType resourceType,
        ResourceSVGLib.Rarity rarity
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256) {
        _validateMint(to, 1, resourceType);

        uint256 tokenId = ++_tokenIdCounter;
        typeMinted[resourceType]++;
        _walletMintCount[to]++;

        _resourceTraits[tokenId] = ResourceSVGLib.ResourceTraits({
            resourceType: resourceType,
            rarity: rarity,
            yieldBonus: _calculateYieldBonus(resourceType, rarity),
            qualityLevel: _calculateQualityLevel(rarity),
            stackSize: 1,
            maxStack: _getMaxStackSize(resourceType)
        });

        _safeMint(to, tokenId);
        emit ResourceMinted(tokenId, to, resourceType, rarity);

        return tokenId;
    }

    function mintRandomResource(
        address to,
        ResourceSVGLib.ResourceType resourceType
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256) {
        _validateMint(to, 1, resourceType);

        uint256 tokenId = ++_tokenIdCounter;
        typeMinted[resourceType]++;
        _walletMintCount[to]++;

        ResourceSVGLib.Rarity rarity = _calculateRarity(tokenId, resourceType, msg.sender);

        _resourceTraits[tokenId] = ResourceSVGLib.ResourceTraits({
            resourceType: resourceType,
            rarity: rarity,
            yieldBonus: _calculateYieldBonus(resourceType, rarity),
            qualityLevel: _calculateQualityLevel(rarity),
            stackSize: 1,
            maxStack: _getMaxStackSize(resourceType)
        });

        _safeMint(to, tokenId);
        emit ResourceMinted(tokenId, to, resourceType, rarity);

        return tokenId;
    }

    function batchMintResources(
        address to,
        ResourceSVGLib.ResourceType[] calldata types,
        ResourceSVGLib.Rarity[] calldata rarities
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused returns (uint256[] memory) {
        require(types.length == rarities.length, "Length mismatch");
        uint256[] memory tokenIds = new uint256[](types.length);

        for (uint256 i = 0; i < types.length; i++) {
            _validateMint(to, 1, types[i]);

            uint256 tokenId = ++_tokenIdCounter;
            typeMinted[types[i]]++;
            _walletMintCount[to]++;

            _resourceTraits[tokenId] = ResourceSVGLib.ResourceTraits({
                resourceType: types[i],
                rarity: rarities[i],
                yieldBonus: _calculateYieldBonus(types[i], rarities[i]),
                qualityLevel: _calculateQualityLevel(rarities[i]),
                stackSize: 1,
                maxStack: _getMaxStackSize(types[i])
            });

            _safeMint(to, tokenId);
            tokenIds[i] = tokenId;

            emit ResourceMinted(tokenId, to, types[i], rarities[i]);
        }

        return tokenIds;
    }

    function _validateMint(address to, uint256 amount, ResourceSVGLib.ResourceType resourceType) private view {
        if (_tokenIdCounter + amount > maxSupply) revert MaxSupplyReached();
        if (typeMinted[resourceType] + amount > typeMaxSupply[resourceType]) revert TypeMaxSupplyReached();
        if (_walletMintCount[to] + amount > maxMintsPerWallet) revert MaxSupplyReached();
        if (uint8(resourceType) > 3) revert InvalidResourceType();
    }

    // ============ STAKING FUNCTIONS ============

    function stakeToNode(uint256 tokenId, uint256 nodeId)
        external
        onlyRole(COLONY_WARS_ROLE)
        nonReentrant
    {
        if (nodeId == 0) revert InvalidResourceType();
        if (_isStaked[tokenId]) revert ResourceAlreadyStaked();

        _isStaked[tokenId] = true;
        _stakedToNode[tokenId] = nodeId;

        emit ResourceStaked(tokenId, nodeId);
    }

    function unstakeFromNode(uint256 tokenId)
        external
        onlyRole(COLONY_WARS_ROLE)
        nonReentrant
    {
        if (!_isStaked[tokenId]) revert ResourceNotStaked();

        uint256 nodeId = _stakedToNode[tokenId];
        _isStaked[tokenId] = false;
        delete _stakedToNode[tokenId];

        emit ResourceUnstaked(tokenId, nodeId);
    }

    // ============ COMBINE FUNCTION ============

    function combineResources(uint256[] calldata tokenIds)
        external
        onlyRole(COLONY_WARS_ROLE)
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        if (tokenIds.length != 3) revert InvalidCombineInput();

        ResourceSVGLib.ResourceType rType = _resourceTraits[tokenIds[0]].resourceType;
        ResourceSVGLib.Rarity baseRarity = _resourceTraits[tokenIds[0]].rarity;

        // Validate all tokens are same type and rarity
        for (uint256 i = 1; i < 3; i++) {
            if (_resourceTraits[tokenIds[i]].resourceType != rType) revert InvalidCombineInput();
            if (_resourceTraits[tokenIds[i]].rarity != baseRarity) revert InvalidCombineInput();
            if (_isStaked[tokenIds[i]]) revert CannotTransferWhileStaked();
        }

        // Cannot upgrade Legendary
        if (baseRarity == ResourceSVGLib.Rarity.Legendary) revert InvalidCombineInput();

        // Burn old tokens
        for (uint256 i = 0; i < 3; i++) {
            _burn(tokenIds[i]);
        }

        // Mint upgraded token
        ResourceSVGLib.Rarity newRarity = ResourceSVGLib.Rarity(uint8(baseRarity) + 1);
        uint256 newTokenId = ++_tokenIdCounter;

        _resourceTraits[newTokenId] = ResourceSVGLib.ResourceTraits({
            resourceType: rType,
            rarity: newRarity,
            yieldBonus: _calculateYieldBonus(rType, newRarity),
            qualityLevel: _calculateQualityLevel(newRarity),
            stackSize: 1,
            maxStack: _getMaxStackSize(rType)
        });

        _safeMint(msg.sender, newTokenId);
        emit ResourcesCombined(tokenIds, newTokenId);

        return newTokenId;
    }

    // ============ VIEW FUNCTIONS ============

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Upgradeable)
        returns (string memory)
    {
        _requireOwned(tokenId);

        ResourceSVGLib.ResourceTraits memory traits = _resourceTraits[tokenId];

        IResourceDescriptor.ResourceMetadata memory metadata = IResourceDescriptor.ResourceMetadata({
            tokenId: tokenId,
            resourceType: traits.resourceType,
            rarity: traits.rarity,
            yieldBonus: traits.yieldBonus,
            qualityLevel: traits.qualityLevel,
            stackSize: traits.stackSize,
            maxStack: traits.maxStack,
            isStaked: _isStaked[tokenId],
            stakedToNode: _stakedToNode[tokenId]
        });

        return metadataRenderer.tokenURI(metadata);
    }

    function contractURI() public view returns (string memory) {
        return metadataRenderer.contractURI();
    }

    function walletMintCount(address wallet) external view returns (uint256) {
        return _walletMintCount[wallet];
    }

    function getTraits(uint256 tokenId)
        external
        view
        returns (ResourceSVGLib.ResourceTraits memory)
    {
        _requireOwned(tokenId);
        return _resourceTraits[tokenId];
    }

    function getStakedNode(uint256 tokenId) external view returns (uint256) {
        return _stakedToNode[tokenId];
    }

    function isStaked(uint256 tokenId) external view returns (bool) {
        return _isStaked[tokenId];
    }

    function getTotalYield(uint256 tokenId) external view returns (uint256) {
        ResourceSVGLib.ResourceTraits memory traits = _resourceTraits[tokenId];
        return uint256(traits.yieldBonus) * uint256(traits.qualityLevel);
    }

    // ============ TRANSFER FUNCTIONS (Model D) ============

    function requestTransfer(uint256 tokenId, address to) external {
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (_isStaked[tokenId]) revert CannotTransferWhileStaked();

        _approvedTransferTarget[tokenId] = to;
        emit TransferRequested(tokenId, msg.sender, to);
    }

    function approveTransfer(uint256 tokenId, address to)
        external
        onlyRole(COLONY_WARS_ROLE)
    {
        _approvedTransferTarget[tokenId] = to;
        emit TransferApproved(tokenId, to);
    }

    function completeTransfer(address from, address to, uint256 tokenId)
        external
        onlyRole(COLONY_WARS_ROLE)
    {
        if (_approvedTransferTarget[tokenId] != to) revert TransferNotApproved();
        if (_isStaked[tokenId]) revert CannotTransferWhileStaked();

        delete _approvedTransferTarget[tokenId];
        _transfer(from, to, tokenId);
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Set the metadata renderer contract
     * @param _metadataRenderer New metadata renderer contract
     */
    function setMetadataRenderer(IResourceDescriptor _metadataRenderer) external onlyRole(ADMIN_ROLE) {
        if (address(_metadataRenderer) == address(0)) revert InvalidMetadataRenderer();

        address oldRenderer = address(metadataRenderer);
        metadataRenderer = _metadataRenderer;

        emit MetadataRendererUpdated(oldRenderer, address(_metadataRenderer));
    }

    function setMaxSupply(uint256 newMaxSupply) external onlyRole(ADMIN_ROLE) {
        require(newMaxSupply >= _tokenIdCounter, "Cannot set below current supply");
        maxSupply = newMaxSupply;
    }

    function setMaxMintsPerWallet(uint256 newLimit) external onlyRole(ADMIN_ROLE) {
        maxMintsPerWallet = newLimit;
    }

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    function updateTypeMaxSupply(
        ResourceSVGLib.ResourceType resourceType,
        uint256 newMax
    ) external onlyRole(ADMIN_ROLE) {
        require(newMax >= typeMinted[resourceType], "Cannot set below minted");
        typeMaxSupply[resourceType] = newMax;
    }

    // ============ INTERNAL FUNCTIONS ============

    function _calculateRarity(
        uint256 tokenId,
        ResourceSVGLib.ResourceType resourceType,
        address minter
    ) private view returns (ResourceSVGLib.Rarity) {
        uint256 randomSeed = uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao,
                    tokenId,
                    minter,
                    block.timestamp,
                    resourceType,
                    block.number
                )
            )
        );

        uint256 roll = randomSeed % 10000;

        if (roll < LEGENDARY_THRESHOLD) return ResourceSVGLib.Rarity.Legendary;
        if (roll < EPIC_THRESHOLD) return ResourceSVGLib.Rarity.Epic;
        if (roll < RARE_THRESHOLD) return ResourceSVGLib.Rarity.Rare;
        if (roll < UNCOMMON_THRESHOLD) return ResourceSVGLib.Rarity.Uncommon;
        return ResourceSVGLib.Rarity.Common;
    }

    /**
     * @notice Calculate yield bonus based on type and rarity
     */
    function _calculateYieldBonus(
        ResourceSVGLib.ResourceType rType,
        ResourceSVGLib.Rarity rarity
    ) private pure returns (uint8) {
        uint8 baseYield;
        if (rType == ResourceSVGLib.ResourceType.BasicMaterials) {
            baseYield = 10;
        } else if (rType == ResourceSVGLib.ResourceType.EnergyCrystals) {
            baseYield = 15;
        } else if (rType == ResourceSVGLib.ResourceType.BioCompounds) {
            baseYield = 12;
        } else {
            baseYield = 20;
        }

        if (rarity == ResourceSVGLib.Rarity.Legendary) return baseYield + 30;
        if (rarity == ResourceSVGLib.Rarity.Epic) return baseYield + 20;
        if (rarity == ResourceSVGLib.Rarity.Rare) return baseYield + 10;
        if (rarity == ResourceSVGLib.Rarity.Uncommon) return baseYield + 5;
        return baseYield;
    }

    /**
     * @notice Calculate quality level based on rarity
     */
    function _calculateQualityLevel(ResourceSVGLib.Rarity rarity) private pure returns (uint8) {
        if (rarity == ResourceSVGLib.Rarity.Legendary) return 5;
        if (rarity == ResourceSVGLib.Rarity.Epic) return 4;
        if (rarity == ResourceSVGLib.Rarity.Rare) return 3;
        if (rarity == ResourceSVGLib.Rarity.Uncommon) return 2;
        return 1;
    }

    /**
     * @notice Get maximum stack size for resource type
     */
    function _getMaxStackSize(ResourceSVGLib.ResourceType rType) private pure returns (uint16) {
        if (rType == ResourceSVGLib.ResourceType.BasicMaterials) return 99;
        if (rType == ResourceSVGLib.ResourceType.EnergyCrystals) return 50;
        if (rType == ResourceSVGLib.ResourceType.BioCompounds) return 25;
        return 10; // RareElements - most limited
    }

    function _checkDiamondPermission() internal view override {
        _checkRole(DIAMOND_ROLE);
    }

    function _tokenExists(uint256 tokenId) internal view override returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    function _authorizeUpgrade(address) internal override onlyRole(ADMIN_ROLE) {}

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (address)
    {
        // Block transfer of staked resources (except burn)
        if (to != address(0) && _isStaked[tokenId]) {
            revert CannotTransferWhileStaked();
        }
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
}
