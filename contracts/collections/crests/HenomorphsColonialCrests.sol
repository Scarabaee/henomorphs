// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import "./CrestTypes.sol";
import "./ICrestMetadata.sol";

/**
 * @title IColonyRegistry
 * @notice Interface for querying colony data from the Henomorphs Diamond
 */
interface IColonyRegistry {
    function getColonyInfo(bytes32 colonyId) external view returns (
        string memory name,
        address creator,
        bool active,
        uint256 stakingBonus,
        uint32 memberCount
    );

    function getColonyWarQuickStats(bytes32 colonyId) external view returns (
        uint256 score,
        uint256 defensiveStake,
        uint256 territoriesControlled,
        bool inAlliance,
        uint256 battlesWon,
        uint256 battlesLost
    );
}

/**
 * @title HenomorphsColonialCrests
 * @notice ERC721 collection of colony coat of arms / crests
 * @dev One crest per colony, mintable only by colony owner
 *
 * Features:
 * - Each colony can only have ONE crest token
 * - Only colony owner (creator) can mint
 * - Token ID = uint256(colonyId) for direct mapping
 * - On-chain metadata generation
 * - Archetype determined from colony stats at mint time
 *
 * @author rutilicus.eth (ZicoDAO)
 */
contract HenomorphsColonialCrests is
    Initializable,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using Strings for uint256;

    // ============ ROLES ============
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ============ EVENTS ============
    event CrestMinted(bytes32 indexed colonyId, uint256 indexed tokenId, address indexed minter, string colonyName);
    event CollectionUpdated(string name, string description);
    event MetadataDescriptorUpdated(address indexed newDescriptor);
    event ColonyRegistryUpdated(address indexed newRegistry);

    // ============ ERRORS ============
    error ColonyNotFound();
    error NotColonyOwner();
    error CrestAlreadyMinted();
    error InvalidColonyRegistry();
    error InvalidMetadataDescriptor();
    error CollectionNotMintable();

    // ============ STORAGE ============
    CrestTypes.Collection private _collection;

    /// @notice Colony registry (Henomorphs Diamond)
    IColonyRegistry public colonyRegistry;

    /// @notice Metadata descriptor contract
    ICrestMetadata public metadataDescriptor;

    /// @notice Mapping: tokenId => crest data
    mapping(uint256 => CrestTypes.CrestData) private _crestData;

    /// @notice Mapping: colonyId (as uint256) => tokenId
    /// @dev Stores which token was minted for each colony (0 = not minted)
    mapping(uint256 => uint256) private _colonyToToken;

    /// @notice Mapping: tokenId => colonyId (as uint256)
    /// @dev Reverse lookup for finding colony by token
    mapping(uint256 => uint256) private _tokenToColony;

    /// @notice Next token ID to mint (starts at 1)
    uint256 private _nextTokenId;

    // ============ INITIALIZER ============
    function initialize(
        string memory name_,
        string memory symbol_,
        string memory description_,
        string memory baseImageUri_,
        string memory contractImageUrl_,
        address colonyRegistry_,
        address metadataDescriptor_
    ) public initializer {
        __ERC721_init(name_, symbol_);
        __ERC721Enumerable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        _nextTokenId = 1;

        _collection = CrestTypes.Collection({
            id: 1,
            name: name_,
            description: description_,
            baseImageUri: baseImageUri_,
            contractImageUrl: contractImageUrl_,
            isMintable: true,
            isFixed: false
        });

        if (colonyRegistry_ == address(0)) revert InvalidColonyRegistry();
        colonyRegistry = IColonyRegistry(colonyRegistry_);

        if (metadataDescriptor_ != address(0)) {
            metadataDescriptor = ICrestMetadata(metadataDescriptor_);
        }
    }

    // ============ MINTING ============

    /**
     * @notice Mint a crest for your colony
     * @param colonyId The bytes32 colony ID
     * @return tokenId The minted token ID
     */
    function mintCrest(bytes32 colonyId) external nonReentrant returns (uint256 tokenId) {
        if (!_collection.isMintable) revert CollectionNotMintable();

        uint256 colonyIdInt = uint256(colonyId);

        // Check if crest already minted for this colony
        if (_colonyToToken[colonyIdInt] != 0) revert CrestAlreadyMinted();

        // Get colony info and verify ownership
        (
            string memory colonyName,
            address creator,
            bool active,
            ,
            uint32 memberCount
        ) = colonyRegistry.getColonyInfo(colonyId);

        if (!active || bytes(colonyName).length == 0) revert ColonyNotFound();
        if (msg.sender != creator) revert NotColonyOwner();

        // Assign sequential token ID (1, 2, 3...)
        tokenId = _nextTokenId++;

        // Get colony stats for attribute determination
        CrestTypes.ColonySnapshot memory snapshot = _getColonySnapshot(colonyId, colonyName, creator, memberCount);
        snapshot.rank = tokenId; // Mint order as rank

        CrestTypes.Archetype archetype = _determineArchetype(snapshot);
        CrestTypes.Heraldry memory heraldry = _determineHeraldry(snapshot, archetype);

        // Store crest data
        _crestData[tokenId] = CrestTypes.CrestData({
            tokenId: tokenId,
            colonyId: colonyId,
            colonyName: colonyName,
            originalMinter: msg.sender,
            mintTimestamp: block.timestamp,
            archetype: archetype,
            heraldry: heraldry
        });

        // Store bidirectional mappings
        _colonyToToken[colonyIdInt] = tokenId;
        _tokenToColony[tokenId] = colonyIdInt;

        _safeMint(msg.sender, tokenId);

        emit CrestMinted(colonyId, tokenId, msg.sender, colonyName);
        return tokenId;
    }

    /**
     * @notice Get colony snapshot for metadata
     * @dev Fetches war stats via getColonyCrestQuickStats for archetype determination
     */
    function _getColonySnapshot(
        bytes32 colonyId,
        string memory colonyName,
        address creator,
        uint32 memberCount
    ) internal view returns (CrestTypes.ColonySnapshot memory snapshot) {
        snapshot.colonyId = colonyId;
        snapshot.name = colonyName;
        snapshot.creator = creator;
        snapshot.memberCount = memberCount;

        // Fetch war stats for archetype determination
        try colonyRegistry.getColonyWarQuickStats(colonyId) returns (
            uint256 score,
            uint256 defensiveStake,
            uint256 territoriesControlled,
            bool inAlliance,
            uint256 battlesWon,
            uint256 battlesLost
        ) {
            snapshot.score = score;
            snapshot.defensiveStake = defensiveStake;
            snapshot.territoriesControlled = territoriesControlled;
            snapshot.inAlliance = inAlliance;
            snapshot.battlesWon = battlesWon;
            snapshot.battlesLost = battlesLost;
        } catch {
            // If call fails, defaults remain 0 (Newborn archetype)
        }

        return snapshot;
    }

    /**
     * @notice Determine archetype based on colony stats
     * @dev Logic mirrors colony-emblem-generator.ts determineArchetype()
     */
    function _determineArchetype(
        CrestTypes.ColonySnapshot memory snapshot
    ) internal pure returns (CrestTypes.Archetype) {
        uint256 totalBattles = snapshot.battlesWon + snapshot.battlesLost;
        uint256 winRate = totalBattles > 0
            ? (snapshot.battlesWon * 100) / totalBattles
            : 0;

        // Aggressive - high battle activity with good win rate
        if (totalBattles > 10 && winRate > 60) {
            return CrestTypes.Archetype.Aggressive;
        }

        // Defensive - high defensive stake, lower offensive activity
        if (snapshot.defensiveStake > 100 ether && snapshot.battlesWon < totalBattles / 2) {
            return CrestTypes.Archetype.Defensive;
        }

        // Wealthy - high earnings
        if (snapshot.totalEarned > 500 ether) {
            return CrestTypes.Archetype.Wealthy;
        }

        // Territorial - many territories controlled
        if (snapshot.territoriesControlled >= 3) {
            return CrestTypes.Archetype.Territorial;
        }

        // Alliance member
        if (snapshot.inAlliance) {
            return CrestTypes.Archetype.Alliance;
        }

        // Veteran - significant battle history
        if (totalBattles > 20) {
            return CrestTypes.Archetype.Veteran;
        }

        // Default - newborn
        return CrestTypes.Archetype.Newborn;
    }

    /**
     * @notice Determine heraldic attributes based on colony stats
     * @dev Shield, Crown, and Beast Pose are derived from stats and archetype
     */
    function _determineHeraldry(
        CrestTypes.ColonySnapshot memory snapshot,
        CrestTypes.Archetype archetype
    ) internal pure returns (CrestTypes.Heraldry memory heraldry) {
        // Determine Shield Type based on archetype
        if (archetype == CrestTypes.Archetype.Defensive) {
            heraldry.shield = CrestTypes.ShieldType.Pavise;  // Large defensive shield
        } else if (archetype == CrestTypes.Archetype.Aggressive) {
            heraldry.shield = CrestTypes.ShieldType.Kite;    // Norman warrior shield
        } else if (archetype == CrestTypes.Archetype.Elite) {
            heraldry.shield = CrestTypes.ShieldType.Lozenge; // Rare diamond shape
        } else if (snapshot.territoriesControlled > 0) {
            heraldry.shield = CrestTypes.ShieldType.Round;   // Versatile buckler
        } else {
            heraldry.shield = CrestTypes.ShieldType.Heater;  // Classic default
        }

        // Determine Crown based on rank and achievements
        if (archetype == CrestTypes.Archetype.Elite) {
            heraldry.crown = CrestTypes.Crown.Imperial;      // Top performers
        } else if (snapshot.battlesWon > 10) {
            heraldry.crown = CrestTypes.Crown.Laurel;        // Battle victors
        } else if (snapshot.inAlliance) {
            heraldry.crown = CrestTypes.Crown.Coronet;       // Alliance nobles
        } else if (snapshot.score > 1000) {
            heraldry.crown = CrestTypes.Crown.Cyber;         // High scorers
        } else {
            heraldry.crown = CrestTypes.Crown.None;          // Newcomers
        }

        // Determine Beast Pose based on battle stats and archetype
        uint256 totalBattles = snapshot.battlesWon + snapshot.battlesLost;
        if (archetype == CrestTypes.Archetype.Elite && snapshot.battlesWon > 20) {
            heraldry.pose = CrestTypes.BeastPose.Triumphant; // Champions
        } else if (archetype == CrestTypes.Archetype.Aggressive) {
            heraldry.pose = CrestTypes.BeastPose.Combatant;  // Warriors
        } else if (archetype == CrestTypes.Archetype.Defensive) {
            heraldry.pose = CrestTypes.BeastPose.Guardian;   // Defenders
        } else if (totalBattles > 5) {
            heraldry.pose = CrestTypes.BeastPose.Rampant;    // Experienced
        } else {
            heraldry.pose = CrestTypes.BeastPose.Vigilant;   // Watchful newcomers
        }

        return heraldry;
    }

    // ============ METADATA ============

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        CrestTypes.CrestData memory crest = _crestData[tokenId];

        if (address(metadataDescriptor) == address(0)) revert InvalidMetadataDescriptor();

        return metadataDescriptor.tokenURI(tokenId, _collection, crest);
    }

    function contractURI() external view returns (string memory) {
        if (address(metadataDescriptor) == address(0)) revert InvalidMetadataDescriptor();
        return metadataDescriptor.contractURI(_collection);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Check if a colony already has a crest
     * @param colonyId The bytes32 colony ID
     */
    function hasColonyCrest(bytes32 colonyId) external view returns (bool) {
        return _colonyToToken[uint256(colonyId)] != 0;
    }

    /**
     * @notice Get token ID for a colony (0 if not minted)
     * @param colonyId The bytes32 colony ID
     */
    function getTokenIdForColony(bytes32 colonyId) external view returns (uint256) {
        return _colonyToToken[uint256(colonyId)];
    }

    /**
     * @notice Get colony ID (as uint256) for a token
     * @param tokenId The token ID
     */
    function getColonyIdForToken(uint256 tokenId) external view returns (uint256) {
        return _tokenToColony[tokenId];
    }

    /**
     * @notice Get crest data for a colony
     * @param colonyId The bytes32 colony ID
     */
    function getCrestData(bytes32 colonyId) external view returns (CrestTypes.CrestData memory) {
        uint256 tokenId = _colonyToToken[uint256(colonyId)];
        return _crestData[tokenId];
    }

    /**
     * @notice Get crest data by token ID
     * @param tokenId The uint256 token ID
     */
    function getCrestDataByTokenId(uint256 tokenId) external view returns (CrestTypes.CrestData memory) {
        return _crestData[tokenId];
    }

    /**
     * @notice Get collection info
     */
    function getCollection() external view returns (CrestTypes.Collection memory) {
        return _collection;
    }

    /**
     * @notice Get total crests minted
     */
    function getTotalMinted() external view returns (uint256) {
        return _nextTokenId - 1;
    }

    /**
     * @notice Check if caller can mint for a colony
     * @param colonyId The bytes32 colony ID
     * @param caller Address to check
     */
    function canMint(bytes32 colonyId, address caller) external view returns (bool canMintCrest, string memory reason) {
        if (!_collection.isMintable) {
            return (false, "Collection not mintable");
        }

        if (_colonyToToken[uint256(colonyId)] != 0) {
            return (false, "Crest already minted");
        }

        try colonyRegistry.getColonyInfo(colonyId) returns (
            string memory colonyName,
            address creator,
            bool active,
            uint256,
            uint32
        ) {
            if (!active || bytes(colonyName).length == 0) {
                return (false, "Colony not found");
            }
            if (caller != creator) {
                return (false, "Not colony owner");
            }
            return (true, "");
        } catch {
            return (false, "Colony not found");
        }
    }

    // ============ ADMIN FUNCTIONS ============

    function updateCollection(
        string memory name_,
        string memory description_,
        string memory baseImageUri_,
        string memory contractImageUrl_
    ) external onlyRole(ADMIN_ROLE) {
        _collection.name = name_;
        _collection.description = description_;
        _collection.baseImageUri = baseImageUri_;
        _collection.contractImageUrl = contractImageUrl_;

        emit CollectionUpdated(name_, description_);
    }

    function setMintable(bool mintable) external onlyRole(ADMIN_ROLE) {
        _collection.isMintable = mintable;
    }

    function setMetadataDescriptor(address newDescriptor) external onlyRole(ADMIN_ROLE) {
        metadataDescriptor = ICrestMetadata(newDescriptor);
        emit MetadataDescriptorUpdated(newDescriptor);
    }

    function setColonyRegistry(address newRegistry) external onlyRole(ADMIN_ROLE) {
        if (newRegistry == address(0)) revert InvalidColonyRegistry();
        colonyRegistry = IColonyRegistry(newRegistry);
        emit ColonyRegistryUpdated(newRegistry);
    }

    // ============ ADMIN MINT (for migration/special cases) ============

    /**
     * @notice Admin mint for specific colony (e.g., migration)
     * @param colonyId Colony ID
     * @param recipient Recipient address
     * @param archetype Override archetype
     * @param heraldry Override heraldic attributes
     */
    function adminMint(
        bytes32 colonyId,
        address recipient,
        CrestTypes.Archetype archetype,
        CrestTypes.Heraldry memory heraldry
    ) external onlyRole(ADMIN_ROLE) nonReentrant returns (uint256 tokenId) {
        uint256 colonyIdInt = uint256(colonyId);

        if (_colonyToToken[colonyIdInt] != 0) revert CrestAlreadyMinted();

        // Get colony info
        (
            string memory colonyName,
            address creator,
            bool active,
            ,

        ) = colonyRegistry.getColonyInfo(colonyId);

        if (!active || bytes(colonyName).length == 0) revert ColonyNotFound();

        // Assign sequential token ID
        tokenId = _nextTokenId++;

        // Store crest data with provided heraldry
        _crestData[tokenId] = CrestTypes.CrestData({
            tokenId: tokenId,
            colonyId: colonyId,
            colonyName: colonyName,
            originalMinter: creator,
            mintTimestamp: block.timestamp,
            archetype: archetype,
            heraldry: heraldry
        });

        // Store bidirectional mappings
        _colonyToToken[colonyIdInt] = tokenId;
        _tokenToColony[tokenId] = colonyIdInt;

        _safeMint(recipient, tokenId);

        emit CrestMinted(colonyId, tokenId, recipient, colonyName);
        return tokenId;
    }

    // ============ REQUIRED OVERRIDES ============

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (address)
    {
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

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(ADMIN_ROLE)
        override
    {}
}
