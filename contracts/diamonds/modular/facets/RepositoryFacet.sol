// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IssuePhase, IssueInfo, ItemTier, TierVariant} from "../libraries/CollectionModel.sol";
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {LibMeta} from "../shared/libraries/LibMeta.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ISpecimenCollection} from "../interfaces/IExternalSystems.sol";

/**
 * @title RepositoryFacet
 * @notice Production collection configuration with variant 0 support
 * @dev Handles variant shuffling and collection issue management
 */
contract RepositoryFacet is AccessControlBase {
    
    // ==================== EVENTS ====================
    
    event CollectionIssuesDefined(uint256 indexed collectionId, uint256 indexed issueId);
    event TiersUpdated(uint256 indexed collectionId, uint256 indexed issueId, uint8 tierCount);
    event VariantsUpdated(uint256 indexed collectionId, uint256 indexed issueId, uint8 tier, uint256 variantCount);
    event CollectionPhaseChanged(uint256 indexed collectionId, uint256 indexed issueId, IssuePhase newPhase);
    event VariantShuffled(uint256 indexed collectionId, uint256 indexed tokenId, uint8 variant, uint256 issueId, uint8 tier, address indexed requester);
    event CollectionRegisteredForVariants(uint256 indexed collectionId, address indexed collectionAddress, uint8 defaultVariant);
    event IssueFixed(uint256 indexed collectionId, uint256 indexed issueId);
    event IssueDeleted(uint256 indexed collectionId, uint256 indexed issueId);
    event TierDeleted(uint256 indexed collectionId, uint256 indexed issueId, uint8 tier);
    event VariantDeleted(uint256 indexed collectionId, uint256 indexed issueId, uint8 tier, uint8 variant);
    event IssueUpdated(uint256 indexed collectionId, uint256 indexed issueId);
    event VariantPricingUpdated(uint256 indexed collectionId, uint8 tier, uint8 variant, uint256 newPrice);
    event VariantCounterFixed(uint256 indexed collectionId, uint8 tier, uint8 variant, uint256 oldCount, uint256 newCount);
    /**
     * @notice Event emitted when user resets their own token variant
     */
    event TokenSelfReset(
        address indexed user,
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        uint8 previousVariant,
        uint256 timestamp
    );
    event WalletLimitUpdated(uint256 indexed collectionId, uint8 indexed tier, uint256 maxMintsPerWallet);

    /**
     * @notice Event emitted when payment is processed for self-reset
     */
    event SelfResetPaymentProcessed(
        address indexed user,
        uint256 amount,
        address indexed currency,
        address indexed beneficiary
    );

    /**
     * @notice Event emitted when token rolling is unlocked
     */
    event TokenRollingUnlocked(
        address indexed user,
        uint256 indexed collectionId,
        uint256 indexed tokenId,
        uint256 timestamp
    );
    event TokenSelfResetFlagReset(uint256 indexed collectionId, uint256 indexed tokenId);
    event BatchVariantResetCompleted(
        uint256 indexed collectionId,
        uint8 indexed tier,
        uint256 tokenCount
    );
    
    // ==================== ERRORS ====================
    
    error InvalidCallData();
    error InvalidIssueData();
    error InvalidIssueState();
    error ItemAlreadyVarianted(uint256 tokenId);
    error InvalidIssueTier(uint8 tier);
    error VariantConfigurationError();
    error InvalidVariantDistribution();
    error InsufficientVariantsAvailable();
    error UnauthorizedVariantOperation(address caller);
    error IssueNotFound(uint256 issueId);
    error TierNotFound(uint8 tier);
    error VariantNotFound(uint8 variant);
    error InvalidPricing();
    error IssueAlreadyExists(uint256 issueId);
    error TierAlreadyExists(uint8 tier);
    error VariantAlreadyExists(uint8 variant);
    error SelfResetAlreadyUsed(uint256 tokenId);
    error SelfResetNotActive();
    error TokenAlreadyAtBaseVariant(uint256 tokenId);
    error TokenNotOwnedByUser(uint256 tokenId, address user);
    error TokenDoesNotExist(uint256 tokenId);
    
    // ==================== CONSTANTS ====================
    
    uint8 private constant MAX_VARIANTS_PER_TIER = 10;
    uint8 private constant MAX_TIERS_PER_ISSUE = 10;

    // ==================== STRUCTS ====================

    struct PricingUpdate {
        uint256 collectionId;
        uint8 tier;
        uint8 variant;
        uint256 newPrice;
    }

    struct BatchVariantConfig {
        uint256 collectionId;
        uint8 tier;
        TierVariant[] variants;
    }

    struct IssueStatistics {
        uint8 tierCount;
        uint256 totalVariants;
        uint256 totalMinted;
        bool isFixed;
        IssuePhase currentPhase;
        uint256 totalMaxSupply;
        uint256 availableSupply;
    }
    
    // ==================== COLLECTION REGISTRATION ====================


    /**
     * @notice Reset self-reset flags for multiple tokens (admin only)
     * @param collectionId Collection ID
     * @param tokenIds Array of token IDs to reset
     */
    function batchResetSelfResetFlags(
        uint256 collectionId,
        uint256[] calldata tokenIds
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            cs.tokenSelfResetUsed[collectionId][tokenId] = false;
            emit TokenSelfResetFlagReset(collectionId, tokenId);
        }
    }

    /**
     * @notice Migrates all itemsVarianted data to collectionItemsVarianted for specific collection
     * @param collectionId Target collection ID to migrate all legacy data to
     * @param maxTokenId Maximum token ID to scan (for gas optimization)
     */
    function migrateAllVariantedItems(
        uint256 collectionId,
        uint256 maxTokenId
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        for (uint256 tokenId = 1; tokenId <= maxTokenId; tokenId++) {
            uint256 legacyValue = cs.itemsVarianted[tokenId];
            
            if (legacyValue > 0) {
                cs.collectionItemsVarianted[collectionId][tokenId] = legacyValue;
                // Optionally clear legacy data:
                // delete cs.itemsVarianted[tokenId];
            }
        }
    }
    
    function registerCollectionForVariants(
        uint256 collectionId,
        address collectionAddress,
        uint8 defaultVariant,
        uint8 defaultTier,
        uint256 defaultIssueId
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        if (collectionAddress == address(0)) revert InvalidCallData();
        if (defaultTier == 0) revert InvalidCallData();
        if (defaultIssueId != collectionId) revert InvalidCallData();
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        collection.defaultVariant = defaultVariant;
        collection.defaultTier = defaultTier;
        collection.defaultIssueId = defaultIssueId;
        collection.lastUpdateTime = block.timestamp;
        
        emit CollectionRegisteredForVariants(collectionId, collectionAddress, defaultVariant);
    }
    
    // ==================== ISSUE MANAGEMENT ====================
    
    function defineCollectionIssues(
        uint256 collectionId,
        IssueInfo calldata issue,
        ItemTier[] calldata tiers
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        if (issue.issueId != collectionId) revert InvalidIssueData();
        _validateIssueData(issue);
        _validateTierData(tiers);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.issueInfos[collectionId].issueId != 0) {
            revert IssueAlreadyExists(collectionId);
        }
        
        cs.issueInfos[collectionId] = issue;
        
        for (uint256 i = 0; i < tiers.length; i++) {
            if (cs.itemTiers[collectionId][tiers[i].tier].tier != 0) {
                revert TierAlreadyExists(tiers[i].tier);
            }
            cs.itemTiers[collectionId][tiers[i].tier] = tiers[i];
        }
        
        cs.tierCounters[collectionId] = uint8(tiers.length);
        
        emit CollectionIssuesDefined(collectionId, collectionId);
        emit TiersUpdated(collectionId, collectionId, uint8(tiers.length));
    }
    
    function updateCollectionIssue(
        uint256 collectionId,
        IssueInfo calldata issue
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        if (issue.issueId != collectionId) revert InvalidIssueData();
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        IssueInfo storage existingIssue = cs.issueInfos[collectionId];
        if (existingIssue.issueId == 0) {
            revert InvalidIssueData();
        }
        
        if (existingIssue.isFixed) {
            revert InvalidIssueState();
        }
        
        cs.issueInfos[collectionId] = issue;
        
        emit IssueUpdated(collectionId, collectionId);
    }

    function deleteCollectionIssue(
        uint256 collectionId
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        IssueInfo storage issue = cs.issueInfos[collectionId];
        if (issue.issueId == 0) {
            revert IssueNotFound(collectionId);
        }
        
        if (issue.isFixed) {
            revert InvalidIssueState();
        }
        
        uint8 tierCount = cs.tierCounters[collectionId];
        for (uint8 tier = 1; tier <= tierCount; tier++) {
            
            for (uint8 variant = 0; variant <= MAX_VARIANTS_PER_TIER; variant++) {
                if (cs.tierVariants[collectionId][tier][variant].tier == tier ||
                    (variant == 0 && cs.tierVariants[collectionId][tier][0].maxSupply > 0)) {
                    delete cs.tierVariants[collectionId][tier][variant];
                    delete cs.hitVariantsCounters[collectionId][tier][variant];
                }
            }
            
            delete cs.itemTiers[collectionId][tier];
        }
        
        delete cs.issueInfos[collectionId];
        delete cs.tierCounters[collectionId];
        
        emit IssueDeleted(collectionId, collectionId);
    }

    function adjustCollectionIssuePhase(
        uint256 collectionId,
        IssuePhase phase
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        IssueInfo storage issue = cs.issueInfos[collectionId];
        if (issue.issueId == 0) {
            revert InvalidIssueData();
        }
        
        issue.issuePhase = phase;
        
        emit CollectionPhaseChanged(collectionId, collectionId, phase);
    }
    
    function toggleCollectionIssueFixed(
        uint256 collectionId
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        IssueInfo storage issue = cs.issueInfos[collectionId];
        if (issue.issueId == 0) {
            revert InvalidIssueData();
        }
        
        issue.isFixed = !issue.isFixed;
        
        emit IssueFixed(collectionId, collectionId);
    }
    
    // ==================== TIER MANAGEMENT ====================
    
    function updateCollectionTiers(
        uint256 collectionId,
        ItemTier[] calldata tiers
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        _validateTierData(tiers);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        IssueInfo storage issue = cs.issueInfos[collectionId];
        if (issue.issueId == 0) {
            revert InvalidIssueData();
        }
        
        if (issue.isFixed) {
            revert InvalidIssueState();
        }
        
        for (uint256 i = 0; i < tiers.length; i++) {
            cs.itemTiers[collectionId][tiers[i].tier] = tiers[i];
        }
        
        cs.tierCounters[collectionId] = uint8(tiers.length);
        
        emit TiersUpdated(collectionId, collectionId, uint8(tiers.length));
    }

    function addCollectionTier(
        uint256 collectionId,
        ItemTier calldata tier
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        IssueInfo storage issue = cs.issueInfos[collectionId];
        if (issue.issueId == 0) {
            revert IssueNotFound(collectionId);
        }
        
        if (issue.isFixed) {
            revert InvalidIssueState();
        }
        
        if (cs.itemTiers[collectionId][tier.tier].tier != 0) {
            revert TierAlreadyExists(tier.tier);
        }
        
        cs.itemTiers[collectionId][tier.tier] = tier;
        cs.tierCounters[collectionId]++;
        
        emit TiersUpdated(collectionId, collectionId, cs.tierCounters[collectionId]);
    }

    function deleteCollectionTier(
        uint256 collectionId,
        uint8 tier
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        IssueInfo storage issue = cs.issueInfos[collectionId];
        if (issue.issueId == 0) {
            revert IssueNotFound(collectionId);
        }
        
        if (issue.isFixed) {
            revert InvalidIssueState();
        }
        
        ItemTier storage itemTier = cs.itemTiers[collectionId][tier];
        if (itemTier.tier == 0) {
            revert TierNotFound(tier);
        }
        
        for (uint8 variant = 0; variant <= MAX_VARIANTS_PER_TIER; variant++) {
            if (cs.tierVariants[collectionId][tier][variant].tier == tier ||
                (variant == 0 && cs.tierVariants[collectionId][tier][0].maxSupply > 0)) {
                delete cs.tierVariants[collectionId][tier][variant];
                delete cs.hitVariantsCounters[collectionId][tier][variant];
            }
        }
        
        delete cs.itemTiers[collectionId][tier];
        
        if (cs.tierCounters[collectionId] > 0) {
            cs.tierCounters[collectionId]--;
        }
        
        emit TierDeleted(collectionId, collectionId, tier);
    }
    
    // ==================== VARIANT MANAGEMENT ====================

    /**
     * @notice Fix variant counter (ADMIN ONLY)
     */
    function fixVariantCounter(
        uint256 collectionId,
        uint8 tier,
        uint8 variant,
        uint256 correctCount
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Validate variant exists
        if (variant == 0) {
            require(cs.tierVariants[collectionId][tier][0].maxSupply > 0, "Variant 0 not found");
        } else {
            require(cs.tierVariants[collectionId][tier][variant].variant != 0, "Variant not found");
        }
        
        uint256 oldCount = cs.hitVariantsCounters[collectionId][tier][variant];
        cs.hitVariantsCounters[collectionId][tier][variant] = correctCount;
        
        emit VariantCounterFixed(collectionId, tier, variant, oldCount, correctCount);
    }
    

    /**
     * @notice Get variant counter value
     */
    function getVariantCounter(
        uint256 collectionId,
        uint8 tier,
        uint8 variant
    ) external view validCollection(collectionId) returns (uint256) {
        return LibCollectionStorage.collectionStorage().hitVariantsCounters[collectionId][tier][variant];
    }
    
    function updateCollectionVariants(
        uint256 collectionId,
        uint8 tier,
        TierVariant[] calldata variants
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        _validateVariantData(variants);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        IssueInfo storage issue = cs.issueInfos[collectionId];
        if (issue.issueId == 0) {
            revert InvalidIssueData();
        }
        
        if (issue.isFixed) {
            revert InvalidIssueState();
        }
        
        for (uint256 i = 0; i < variants.length; i++) {
            if (variants[i].tier != tier) {
                revert VariantConfigurationError();
            }
            
            cs.tierVariants[collectionId][variants[i].tier][variants[i].variant] = variants[i];
        }
        
        // Count only actual variants (1-N), not variant 0
        uint256 actualVariantsCount = 0;
        for (uint256 i = 0; i < variants.length; i++) {
            if (variants[i].variant > 0) {
                actualVariantsCount++;
            }
        }
        
        cs.itemTiers[collectionId][tier].variantsCount = actualVariantsCount;
        
        emit VariantsUpdated(collectionId, collectionId, tier, actualVariantsCount);
    }

    // FIXED: Add single variant to tier (supports variant 0)
    function addCollectionVariant(
        uint256 collectionId,
        TierVariant calldata variant
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        IssueInfo storage issue = cs.issueInfos[collectionId];
        if (issue.issueId == 0) {
            revert IssueNotFound(collectionId);
        }
        
        if (issue.isFixed) {
            revert InvalidIssueState();
        }
        
        // Check if variant already exists (handles variant 0)
        if (variant.variant == 0) {
            if (cs.tierVariants[collectionId][variant.tier][0].maxSupply > 0) {
                revert VariantAlreadyExists(variant.variant);
            }
        } else {
            if (cs.tierVariants[collectionId][variant.tier][variant.variant].variant != 0) {
                revert VariantAlreadyExists(variant.variant);
            }
        }
        
        // Initialize ItemTier if it doesn't exist
        ItemTier storage itemTier = cs.itemTiers[collectionId][variant.tier];
        if (itemTier.tier == 0) {
            itemTier.tier = variant.tier;
            itemTier.collectionId = collectionId;
            itemTier.maxSupply = 0;
            itemTier.price = variant.mintPrice;
            itemTier.isMintable = true;
            itemTier.variantsCount = 0;
        }
        
        cs.tierVariants[collectionId][variant.tier][variant.variant] = variant;
        
        // Only increment counter for actual variants (1-N), not variant 0
        if (variant.variant > 0) {
            itemTier.variantsCount++;
        }
        
        itemTier.maxSupply += variant.maxSupply;
        
        emit VariantsUpdated(collectionId, collectionId, variant.tier, itemTier.variantsCount);
    }

    function deleteCollectionVariant(
        uint256 collectionId,
        uint8 tier,
        uint8 variant
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        IssueInfo storage issue = cs.issueInfos[collectionId];
        if (issue.issueId == 0) {
            revert IssueNotFound(collectionId);
        }
        
        if (issue.isFixed) {
            revert InvalidIssueState();
        }
        
        // Check if variant exists
        if (variant == 0) {
            if (cs.tierVariants[collectionId][tier][0].maxSupply == 0) {
                revert VariantNotFound(variant);
            }
        } else {
            if (cs.tierVariants[collectionId][tier][variant].variant == 0) {
                revert VariantNotFound(variant);
            }
        }
        
        delete cs.tierVariants[collectionId][tier][variant];
        delete cs.hitVariantsCounters[collectionId][tier][variant];
        
        // Only decrement counter for actual variants (1-N)
        if (variant > 0) {
            ItemTier storage itemTier = cs.itemTiers[collectionId][tier];
            if (itemTier.variantsCount > 0) {
                itemTier.variantsCount--;
            }
        }
        
        emit VariantDeleted(collectionId, collectionId, tier, variant);
    }

    function updateVariantPricing(
        PricingUpdate[] calldata updates
    ) external onlyAuthorized whenNotPaused {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        for (uint256 i = 0; i < updates.length; i++) {
            PricingUpdate calldata update = updates[i];
            
            if (!LibCollectionStorage.collectionExists(update.collectionId)) {
                continue;
            }
            
            IssueInfo storage issue = cs.issueInfos[update.collectionId];
            if (issue.issueId == 0) continue;
            
            if (issue.isFixed) continue;
            
            TierVariant storage tierVariant = cs.tierVariants[update.collectionId][update.tier][update.variant];
            if ((update.variant == 0 && tierVariant.maxSupply == 0) || 
                (update.variant > 0 && tierVariant.variant == 0)) continue;
            
            tierVariant.mintPrice = update.newPrice;
            
            emit VariantPricingUpdated(update.collectionId, update.tier, update.variant, update.newPrice);
        }
    }

    function updateVariantPricingWithExchange(
        PricingUpdate[] calldata updates,
        bool convertFromQuote
    ) external onlyAuthorized whenNotPaused {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        for (uint256 i = 0; i < updates.length; i++) {
            PricingUpdate calldata update = updates[i];
            
            if (!LibCollectionStorage.collectionExists(update.collectionId)) {
                continue;
            }
            
            IssueInfo storage issue = cs.issueInfos[update.collectionId];
            if (issue.issueId == 0) continue;
            
            if (issue.isFixed) continue;
            
            TierVariant storage tierVariant = cs.tierVariants[update.collectionId][update.tier][update.variant];
            if ((update.variant == 0 && tierVariant.maxSupply == 0) || 
                (update.variant > 0 && tierVariant.variant == 0)) continue;
            
            uint256 finalPrice = update.newPrice;
            
            if (convertFromQuote && LibCollectionStorage.isExchangeConfigured()) {
                (uint256 derivedPrice,) = LibCollectionStorage.derivePriceFromExchange(
                    update.newPrice,
                    [uint80(0), uint80(0)]
                );
                
                if (derivedPrice > 0) {
                    finalPrice = derivedPrice;
                }
            }
            
            tierVariant.mintPrice = finalPrice;
            
            emit VariantPricingUpdated(update.collectionId, update.tier, update.variant, finalPrice);
        }
    }

    function batchConfigureVariants(
        BatchVariantConfig[] calldata configs
    ) external onlyAuthorized whenNotPaused {
        
        for (uint256 i = 0; i < configs.length; i++) {
            BatchVariantConfig calldata config = configs[i];
            
            if (!LibCollectionStorage.collectionExists(config.collectionId)) {
                continue;
            }
            
            try this.updateCollectionVariants(config.collectionId, config.tier, config.variants) {
                // Success
            } catch {
                // Continue with next config if this one fails
                continue;
            }
        }
    }
    
    // ==================== VARIANT ASSIGNMENT ====================
    
    function shuffleTokenVariant(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId
    ) external onlySystem validCollection(collectionId) returns (uint8) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.collectionItemsVarianted[collectionId][tokenId] != 0) {
            revert ItemAlreadyVarianted(tokenId);
        }
        
        ItemTier storage itemTier = cs.itemTiers[collectionId][tier];
        if (itemTier.variantsCount <= 1) {
            LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
            return collection.defaultVariant > 0 ? collection.defaultVariant : 1;
        }
            
        uint8 selectedVariant = _performVariantShuffle(
            collectionId, 
            tier, 
            tokenId, 
            itemTier
        );
        
        cs.collectionItemsVarianted[collectionId][tokenId] = block.number;
        cs.hitVariantsCounters[collectionId][tier][selectedVariant]++;
        cs.itemsVariants[collectionId][tier][tokenId] = selectedVariant;
        
        emit VariantShuffled(collectionId, tokenId, selectedVariant, collectionId, tier, LibMeta.msgSender());
        
        return selectedVariant;
    }

    function selectVariant(
        uint256 collectionId,
        uint8 tier,
        uint256 seed
    ) external view validCollection(collectionId) returns (uint8) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        ItemTier storage itemTier = cs.itemTiers[collectionId][tier];
        if (itemTier.variantsCount <= 1) {
            return cs.collections[collectionId].defaultVariant;
        }
        
        uint8[] memory availableVariants = new uint8[](itemTier.variantsCount);
        uint256[] memory variantWeights = new uint256[](itemTier.variantsCount);
        uint256 totalWeight = 0;
        uint256 availableCount = 0;
        
        for (uint8 v = 1; v <= MAX_VARIANTS_PER_TIER && availableCount < itemTier.variantsCount; v++) {
            TierVariant storage variant = cs.tierVariants[collectionId][tier][v];
            if (variant.tier == tier && variant.maxSupply > 0 && variant.active) {
                uint256 minted = cs.hitVariantsCounters[collectionId][tier][v];
                if (minted < variant.maxSupply) {
                    uint256 available = variant.maxSupply - minted;
                    availableVariants[availableCount] = v;
                    variantWeights[availableCount] = available;
                    totalWeight += available;
                    availableCount++;
                }
            }
        }
        
        if (totalWeight == 0) {
            revert InsufficientVariantsAvailable();
        }
        
        uint256 randomValue = seed % totalWeight;
        
        uint256 currentWeight = 0;
        for (uint256 i = 0; i < availableCount; i++) {
            currentWeight += variantWeights[i];
            if (randomValue < currentWeight) {
                return availableVariants[i];
            }
        }
        
        return availableVariants[0];
    }

    function forceAssignVariant(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint8 variant
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // if (cs.collectionItemsVarianted[collectionId][tokenId] != 0) {
        //     revert ItemAlreadyVarianted(tokenId);
        // }
        
        // Check if variant exists
        if (variant == 0) {
            if (cs.tierVariants[collectionId][tier][0].maxSupply == 0) {
                revert VariantNotFound(variant);
            }
        } else {
            if (cs.tierVariants[collectionId][tier][variant].variant == 0) {
                revert VariantNotFound(variant);
            }
        }
        
        cs.collectionItemsVarianted[collectionId][tokenId] = block.number;
        cs.hitVariantsCounters[collectionId][tier][variant]++;
        cs.itemsVariants[collectionId][tier][tokenId] = variant;

        (address collectionAddress,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (exists && collectionAddress != address(0)) {
            try ISpecimenCollection(collectionAddress).assignVariant(collectionId, tier, tokenId, variant) {
                // Success - Collection reset local storage
            } catch {
                // Collection doesn't support reset - that's OK
            }
        }
        
        emit VariantShuffled(collectionId, tokenId, variant, collectionId, tier, LibMeta.msgSender());
    }

    function resetVariantAssignment(uint256 collectionId, uint8 tier, uint256 tokenId) external onlyAuthorized whenNotPaused {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint8 variant = cs.itemsVariants[collectionId][tier][tokenId];
        if (variant > 0) {
            unchecked {
                cs.hitVariantsCounters[collectionId][tier][variant]--;
            }
        }
        
        delete cs.itemsVariants[collectionId][tier][tokenId];
        delete cs.collectionItemsVarianted[collectionId][tokenId];
        
        (address collectionAddress,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (exists && collectionAddress != address(0)) {
            try ISpecimenCollection(collectionAddress).resetVariant(collectionId, tier, tokenId) {
                // Success - Collection reset local storage
            } catch {
                // Collection doesn't support reset - that's OK
            }
        }
    }

    /**
     * @notice Batch reset variant assignments for multiple tokens (admin only)
     * @param collectionId Collection ID
     * @param tier Tier number
     * @param tokenIds Array of token IDs to reset
     */
    function batchResetVariantAssignment(
        uint256 collectionId, 
        uint8 tier, 
        uint256[] calldata tokenIds
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        if (tokenIds.length == 0) {
            revert InvalidCallData();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Get collection info once for gas optimization
        (address collectionAddress,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        bool notifyCollection = exists && collectionAddress != address(0);
        
        // Process each token
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            // Get current variant
            uint8 variant = cs.itemsVariants[collectionId][tier][tokenId];
            
            // Decrement counter only if variant was assigned
            if (variant > 0) {
                unchecked {
                    cs.hitVariantsCounters[collectionId][tier][variant]--;
                }
            }
            
            // Reset storage mappings
            delete cs.itemsVariants[collectionId][tier][tokenId];
            delete cs.collectionItemsVarianted[collectionId][tokenId];
            
            // Notify collection contract if possible
            if (notifyCollection) {
                try ISpecimenCollection(collectionAddress).resetVariant(collectionId, tier, tokenId) {
                    // Success - Collection reset local storage
                } catch {
                    // Collection doesn't support reset - that's OK, continue
                }
            }
        }
        
        // Emit batch completion event
        emit BatchVariantResetCompleted(collectionId, tier, tokenIds.length);
    }

    /**
     * @notice User can reset their own token variant once (one-time operation)
     * @dev Allows token owner to reset variant back to 0, requires ZICO payment
     * @param collectionId Collection ID
     * @param tokenId Token ID to reset (must be owned by msg.sender)
     */
    function ownerResetTokenVariant(
        uint256 collectionId,
        uint256 tokenId,
        bool unlockRolling
    ) external whenNotPaused nonReentrant {
        address owner = LibMeta.msgSender();
        
        // Validate collection exists
        if (!LibCollectionStorage.collectionExists(collectionId)) {
            revert CollectionNotFound(collectionId);
        }
        
        // Get collection info
        (, uint8 tier, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists) {
            revert InvalidCallData();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Check if self-reset is configured and active
        LibCollectionStorage.SelfResetPricing storage resetPricing = cs.selfResetPricingByTier[collectionId][tier];
        if (!resetPricing.isActive) {
            revert SelfResetNotActive();
        }
        
        // Check if token has been reset before (one-time only)
        if (cs.tokenSelfResetUsed[collectionId][tokenId]) {
            revert SelfResetAlreadyUsed(tokenId);
        }
        
        // Validate token ownership
        _validateTokenOwnership(owner, collectionId, tokenId);
        
        // Get current variant
        uint8 currentVariant = cs.itemsVariants[collectionId][tier][tokenId];
        if (currentVariant == 0) {
            revert TokenAlreadyAtBaseVariant(tokenId);
        }
        
        // Check if variant 0 is configured before allowing reset
        if (cs.tierVariants[collectionId][tier][0].maxSupply == 0) {
            revert("Variant 0 not configured");
        }
        
        // Process payment (double fee if unlockRolling is true)
        _processSelfResetPayment(owner, resetPricing.resetFee, unlockRolling);
        
        // Mark token as having used self-reset (prevents future resets)
        cs.tokenSelfResetUsed[collectionId][tokenId] = true;
        
        // CRITICAL: Token keeps its current variant and varianted status
        // Do NOT reset cs.itemsVariants or cs.collectionItemsVarianted!
        // The actual reset will happen when new variant is assigned
        
        // Only unlock rolling if user paid for it
        if (unlockRolling) {
            cs.tokenRollingUnlocked[collectionId][tokenId] = true;
            // Note: Do NOT clear cs.collectionItemsVarianted! Token remains "varianted"
        }
        // If unlockRolling = false, user cannot roll and thus cannot trigger actual reset
        
        // Note: Collection contract will be notified about the actual reset
        // when new variant is assigned through the normal assignment flow
        
        emit TokenSelfReset(owner, collectionId, tokenId, currentVariant, block.timestamp);
        
        if (unlockRolling) {
            emit TokenRollingUnlocked(owner, collectionId, tokenId, block.timestamp);
        }
    }

    function updateVariantCounters(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        uint8 variant
    ) external onlySystem validCollection(collectionId) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Get current variant of the token
        uint8 currentVariant = cs.itemsVariants[collectionId][tier][tokenId];
        
        // If token already has this variant, no change needed
        if (currentVariant == variant) {
            return;
        }
        
        // Ensure token exists in the collection contract
        (address collectionAddress,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (exists && collectionAddress != address(0)) {
            try IERC721(collectionAddress).ownerOf(tokenId) returns (address) {
                // Token exists, proceed
            } catch {
                // Token doesn't exist in collection, don't count
                return;
            }
        }
        
        // Validate that the target variant exists
        if (variant == 0) {
            if (cs.tierVariants[collectionId][tier][0].maxSupply == 0) {
                revert VariantNotFound(variant);
            }
        } else {
            if (cs.tierVariants[collectionId][tier][variant].variant == 0) {
                revert VariantNotFound(variant);
            }
        }
        
        // FIXED: Handle variant transitions properly
        
        // Case 1: Transition from variant 0 (unassigned) to specific variant
        if (currentVariant == 0 && variant != 0) {
            // Decrement variant 0 counter (token leaving unassigned state)
            if (cs.tierVariants[collectionId][tier][0].maxSupply > 0) {
                if (cs.hitVariantsCounters[collectionId][tier][0] > 0) {
                    cs.hitVariantsCounters[collectionId][tier][0]--;
                }
            }
        }
        // Case 2: Transition from specific variant to variant 0 (reset to unassigned)
        else if (currentVariant != 0 && variant == 0) {
            // Decrement previous variant counter
            if (cs.hitVariantsCounters[collectionId][tier][currentVariant] > 0) {
                cs.hitVariantsCounters[collectionId][tier][currentVariant]--;
            }
        }
        // Case 3: Transition from one specific variant to another specific variant
        else if (currentVariant != 0 && variant != 0 && currentVariant != variant) {
            // Decrement previous variant counter
            if (cs.hitVariantsCounters[collectionId][tier][currentVariant] > 0) {
                cs.hitVariantsCounters[collectionId][tier][currentVariant]--;
            }
        }
        
        // Increment counter for new variant
        cs.hitVariantsCounters[collectionId][tier][variant]++;
        
        // Update token mappings
        cs.collectionItemsVarianted[collectionId][tokenId] = block.number;
        cs.itemsVariants[collectionId][tier][tokenId] = variant;

        if (variant != 0) {
            cs.tokenRollingUnlocked[collectionId][tokenId] = false;
        }
        
        emit VariantShuffled(collectionId, tokenId, variant, collectionId, tier, LibMeta.msgSender());
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    function getIssueInfo(uint256 collectionId) external view returns (IssueInfo memory) {
        return LibCollectionStorage.collectionStorage().issueInfos[collectionId];
    }

    function getMultipleIssues(uint256[] calldata collectionIds) external view returns (IssueInfo[] memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        IssueInfo[] memory issues = new IssueInfo[](collectionIds.length);
        
        for (uint256 i = 0; i < collectionIds.length; i++) {
            issues[i] = cs.issueInfos[collectionIds[i]];
        }
        
        return issues;
    }

    function getIssuesByCollection(
        uint256 offset,
        uint256 limit
    ) external view returns (IssueInfo[] memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        IssueInfo[] memory result = new IssueInfo[](limit);
        uint256 count = 0;
        uint256 found = 0;
        
        for (uint256 collectionId = 1; collectionId < cs.collectionCounter && count < limit; collectionId++) {
            IssueInfo storage issue = cs.issueInfos[collectionId];
            if (issue.issueId != 0) {
                if (found >= offset) {
                    result[count] = issue;
                    count++;
                }
                found++;
            }
        }
        
        assembly {
            mstore(result, count)
        }
        
        return result;
    }
    
    function getCollectionItemInfo(uint256 collectionId, uint8 tier) external view returns (
        IssueInfo memory,
        ItemTier memory
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        return (
            cs.issueInfos[collectionId],
            cs.itemTiers[collectionId][tier]
        );
    }

    function getIssueTiers(uint256 collectionId) external view returns (ItemTier[] memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint8 tierCount = cs.tierCounters[collectionId];
        ItemTier[] memory tiers = new ItemTier[](tierCount);
        uint256 foundTiers = 0;
        
        for (uint8 tier = 1; tier <= MAX_TIERS_PER_ISSUE && foundTiers < tierCount; tier++) {
            ItemTier storage itemTier = cs.itemTiers[collectionId][tier];
            if (itemTier.tier != 0) {
                tiers[foundTiers] = itemTier;
                foundTiers++;
            }
        }
        
        return tiers;
    }
    
    function getCollectionTiersCount(uint256 collectionId) external view returns (uint8) {
        return LibCollectionStorage.collectionStorage().tierCounters[collectionId];
    }
    
    function getCollectionTierVariant(
        uint256 collectionId,
        uint8 tier,
        uint8 variant
    ) external view returns (TierVariant memory) {
        return LibCollectionStorage.collectionStorage().tierVariants[collectionId][tier][variant];
    }
    
    // FIXED: Get all variants for specific tier (includes variant 0 if exists)
    function getCollectionTierVariants(
        uint256 collectionId,
        uint8 tier
    ) external view returns (TierVariant[] memory variants) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        // Count all variants including variant 0
        uint256 totalVariantsCount = 0;
        
        // Check variant 0
        if (cs.tierVariants[collectionId][tier][0].maxSupply > 0) {
            totalVariantsCount++;
        }
        
        // Check variants 1-N
        for (uint8 variantId = 1; variantId <= MAX_VARIANTS_PER_TIER; variantId++) {
            TierVariant storage variant = cs.tierVariants[collectionId][tier][variantId];
            if (variant.tier == tier && variant.maxSupply > 0) {
                totalVariantsCount++;
            }
        }
        
        // Create array with actual size
        variants = new TierVariant[](totalVariantsCount);
        
        uint256 foundVariants = 0;
        
        // Add variant 0 if exists
        if (cs.tierVariants[collectionId][tier][0].maxSupply > 0) {
            variants[foundVariants] = cs.tierVariants[collectionId][tier][0];
            foundVariants++;
        }
        
        // Add variants 1-N
        for (uint8 variantId = 1; variantId <= MAX_VARIANTS_PER_TIER && foundVariants < totalVariantsCount; variantId++) {
            TierVariant storage variant = cs.tierVariants[collectionId][tier][variantId];
            if (variant.tier == tier && variant.maxSupply > 0) {
                variants[foundVariants] = variant;
                foundVariants++;
            }
        }
        
        return variants;
    }

    function getVariantStats(
        uint256 collectionId,
        uint8 tier,
        uint8 variant
    ) external view validCollection(collectionId) returns (
        uint256 maxSupply,
        uint256 currentSupply,
        uint256 mintPrice,
        bool active
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        TierVariant storage tierVariant = cs.tierVariants[collectionId][tier][variant];
        uint256 minted = cs.hitVariantsCounters[collectionId][tier][variant];
        
        return (
            tierVariant.maxSupply,
            minted,
            tierVariant.mintPrice,
            tierVariant.active
        );
    }

    function getVariantPricing(
        uint256 collectionId,
        uint8 tier,
        uint8[] calldata variants,
        bool convertToQuote
    ) external view returns (uint256[] memory prices, bool converted) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        prices = new uint256[](variants.length);
        converted = false;
        
        for (uint256 i = 0; i < variants.length; i++) {
            TierVariant storage tierVariant = cs.tierVariants[collectionId][tier][variants[i]];
            uint256 basePrice = tierVariant.mintPrice;
            
            if (convertToQuote && LibCollectionStorage.isExchangeConfigured() && basePrice > 0) {
                prices[i] = basePrice;
                converted = true;
            } else {
                prices[i] = basePrice;
            }
        }
    }
    
    function getTokenVariantStatus(uint256 collectionId, uint256 tokenId) external view returns (uint256) {
        return LibCollectionStorage.collectionStorage().collectionItemsVarianted[collectionId][tokenId];
    }

    function getTokenVariant(uint256 collectionId, uint256 tokenId, uint8 tier) external view returns (uint8) {
        return LibCollectionStorage.collectionStorage().itemsVariants[collectionId][tier][tokenId];
    }

    /**
     * @notice Get comprehensive token reset status
     */
    function getTokenResetStatus(
        uint256 collectionId,
        uint256 tokenId
    ) external view returns (
        bool hasUsedReset,
        bool rollingUnlocked,
        uint8 currentVariant,
        bool canRollAgain
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        hasUsedReset = cs.tokenSelfResetUsed[collectionId][tokenId];
        rollingUnlocked = cs.tokenRollingUnlocked[collectionId][tokenId];
        
        (, uint8 tier,) = LibCollectionStorage.getCollectionInfo(collectionId);
        currentVariant = cs.itemsVariants[collectionId][tier][tokenId];
        
        // Can roll if: variant is 0 OR rolling is unlocked
        canRollAgain = (currentVariant == 0) || rollingUnlocked;
    }

    function getMultipleTokenVariants(uint256 collectionId, uint256[] calldata tokenIds, uint8 tier) external view returns (uint8[] memory) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint8[] memory variants = new uint8[](tokenIds.length);
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            variants[i] = cs.itemsVariants[collectionId][tier][tokenIds[i]];
        }
        
        return variants;
    }
    
    function getCollectionDefaults(uint256 collectionId) external view returns (
        uint8 defaultVariant,
        uint8 defaultTier,
        uint256 defaultIssueId
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        AccessHelper.requireValidCollection(collectionId);
        
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        return (collection.defaultVariant, collection.defaultTier, collection.defaultIssueId);
    }

    function issueExists(uint256 collectionId) external view returns (bool) {
        return LibCollectionStorage.collectionStorage().issueInfos[collectionId].issueId != 0;
    }

    function tierExists(uint256 collectionId, uint8 tier) external view returns (bool) {
        return LibCollectionStorage.collectionStorage().itemTiers[collectionId][tier].tier != 0;
    }

    function variantExists(uint256 collectionId, uint8 tier, uint8 variant) external view returns (bool) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        if (variant == 0) {
            return cs.tierVariants[collectionId][tier][0].maxSupply > 0;
        }
        return cs.tierVariants[collectionId][tier][variant].variant != 0;
    }

    function getIssueStatistics(uint256 collectionId) external view returns (IssueStatistics memory stats) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        IssueInfo storage issue = cs.issueInfos[collectionId];
        if (issue.issueId == 0) {
            return stats;
        }
        
        stats.tierCount = cs.tierCounters[collectionId];
        stats.isFixed = issue.isFixed;
        stats.currentPhase = issue.issuePhase;
        
        for (uint8 tier = 1; tier <= stats.tierCount; tier++) {
            ItemTier storage itemTier = cs.itemTiers[collectionId][tier];
            stats.totalVariants += itemTier.variantsCount;
            stats.totalMaxSupply += itemTier.maxSupply;
            
            // Count variant 0 if exists
            if (cs.tierVariants[collectionId][tier][0].maxSupply > 0) {
                uint256 minted = cs.hitVariantsCounters[collectionId][tier][0];
                stats.totalMinted += minted;
                if (cs.tierVariants[collectionId][tier][0].maxSupply > minted) {
                    stats.availableSupply += (cs.tierVariants[collectionId][tier][0].maxSupply - minted);
                }
            }
            
            // Count variants 1-N
            for (uint8 variant = 1; variant <= MAX_VARIANTS_PER_TIER; variant++) {
                uint256 minted = cs.hitVariantsCounters[collectionId][tier][variant];
                stats.totalMinted += minted;
                
                TierVariant storage tierVariant = cs.tierVariants[collectionId][tier][variant];
                if (tierVariant.maxSupply > minted) {
                    stats.availableSupply += (tierVariant.maxSupply - minted);
                }
            }
        }
        
        return stats;
    }

    function getBatchVariantStats(
        uint256[] calldata collectionIds,
        uint8[] calldata tiers,
        uint8[] calldata variants
    ) external view returns (
        uint256[] memory maxSupplies,
        uint256[] memory currentSupplies,
        uint256[] memory mintPrices,
        bool[] memory activeStates
    ) {
        require(collectionIds.length == tiers.length && tiers.length == variants.length, "Array length mismatch");
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 length = collectionIds.length;
        maxSupplies = new uint256[](length);
        currentSupplies = new uint256[](length);
        mintPrices = new uint256[](length);
        activeStates = new bool[](length);
        
        for (uint256 i = 0; i < length; i++) {
            TierVariant storage tierVariant = cs.tierVariants[collectionIds[i]][tiers[i]][variants[i]];
            uint256 minted = cs.hitVariantsCounters[collectionIds[i]][tiers[i]][variants[i]];
            
            maxSupplies[i] = tierVariant.maxSupply;
            currentSupplies[i] = minted;
            mintPrices[i] = tierVariant.mintPrice;
            activeStates[i] = tierVariant.active;
        }
        
        return (maxSupplies, currentSupplies, mintPrices, activeStates);
    }

    /**
     * @notice Check if token has used self-reset (view function)
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return used Whether self-reset has been used for this token
     */
    function hasTokenUsedSelfReset(
        uint256 collectionId,
        uint256 tokenId
    ) external view returns (bool used) {
        return LibCollectionStorage.collectionStorage().tokenSelfResetUsed[collectionId][tokenId];
    }

    /**
     * @notice Check if user can reset their token (eligibility check)
     * @param owner User address
     * @param collectionId Collection ID
     * @param tokenId Token ID
     */
    function canUserResetToken(
        address owner,
        uint256 collectionId,
        uint256 tokenId
    ) external view returns (
        bool canReset, 
        string memory reason, 
        uint256 standardFee,
        uint256 unlockFee
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (!LibCollectionStorage.collectionExists(collectionId)) {
            return (false, "Collection not found", 0, 0);
        }
        
        (, uint8 tier, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists) {
            return (false, "Collection not configured", 0, 0);
        }
        
        LibCollectionStorage.SelfResetPricing storage resetPricing = cs.selfResetPricingByTier[collectionId][tier];
        if (!resetPricing.isActive) {
            return (false, "Self-reset not available", 0, 0);
        }
        
        standardFee = resetPricing.resetFee.amount;
        unlockFee = standardFee * 2;
        
        if (cs.tokenSelfResetUsed[collectionId][tokenId]) {
            return (false, "Self-reset already used", standardFee, unlockFee);
        }
        
        // Check if variant 0 is configured
        if (cs.tierVariants[collectionId][tier][0].maxSupply == 0) {
            return (false, "Variant 0 not configured", standardFee, unlockFee);
        }
        
        (address collectionAddress,, bool collectionExists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!collectionExists || collectionAddress == address(0)) {
            return (false, "Collection not configured", standardFee, unlockFee);
        }
        
        try IERC721(collectionAddress).ownerOf(tokenId) returns (address _owner) {
            if (_owner != owner) {
                return (false, "Not token owner", standardFee, unlockFee);
            }
        } catch {
            return (false, "Token does not exist", standardFee, unlockFee);
        }
        
        uint8 currentVariant = cs.itemsVariants[collectionId][tier][tokenId];
        if (currentVariant == 0) {
            return (false, "Token already at base variant", standardFee, unlockFee);
        }
        
        return (true, "Can reset", standardFee, unlockFee);
    }

    /**
     * @notice Set wallet limit for collection tier
     */
    function setWalletLimit(
        uint256 collectionId,
        uint8 tier,
        uint256 maxMintsPerWallet
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        cs.mintPricingByTier[collectionId][tier].maxMintsPerWallet = maxMintsPerWallet;
        
        emit WalletLimitUpdated(collectionId, tier, maxMintsPerWallet);
    }

    function getWalletLimit(uint256 collectionId, uint8 tier) external view returns (uint256 walletLimit) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        walletLimit = cs.mintPricingByTier[collectionId][tier].maxMintsPerWallet;
    }

    /**
     * @notice Get wallet stats for user
     */
    function getWalletStats(
        uint256 collectionId,
        uint8 tier,
        address wallet
    ) external view validCollection(collectionId) returns (
        uint256 totalMints,     // total w całej kolekcji
        uint256 walletLimit,    // limit dla tego tier'a
        uint256 remaining       // ile zostało
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        totalMints = LibCollectionStorage.getTotalWalletMints(collectionId, wallet);
        walletLimit = cs.mintPricingByTier[collectionId][tier].maxMintsPerWallet;
        
        if (walletLimit == 0) {
            remaining = type(uint256).max; // unlimited
        } else if (totalMints >= walletLimit) {
            remaining = 0;
        } else {
            remaining = walletLimit - totalMints;
        }
    }
        
    // ==================== INTERNAL FUNCTIONS ====================

    /**
     * @notice Process payment for self-reset using existing ControlFee pattern
     */
    function _processSelfResetPayment(
        address user,
        LibCollectionStorage.ControlFee storage resetFee,
        bool unlockRolling
    ) internal {
        // Calculate actual fee: double if unlocking rolling
        uint256 actualAmount = unlockRolling ? resetFee.amount * 2 : resetFee.amount;
        
        LibFeeCollection.collectFee(
            resetFee.currency,
            LibMeta.msgSender(),
            resetFee.beneficiary,
            actualAmount,
            "reset_variant"
        );

        emit SelfResetPaymentProcessed(user, actualAmount, resetFee.currency, resetFee.beneficiary);
    }

    /**
     * @notice Validate token ownership (reuse existing ownership validation pattern)
     */
    function _validateTokenOwnership(
        address user,
        uint256 collectionId,
        uint256 tokenId
    ) internal view {
        (address collectionAddress,, bool exists) = LibCollectionStorage.getCollectionInfo(collectionId);
        if (!exists || collectionAddress == address(0)) {
            revert InvalidCallData();
        }
        
        try IERC721(collectionAddress).ownerOf(tokenId) returns (address owner) {
            if (owner != user) {
                revert TokenNotOwnedByUser(tokenId, user);
            }
        } catch {
            revert TokenDoesNotExist(tokenId);
        }
    }

    function _validateIssueData(IssueInfo calldata issue) internal pure {
        if (issue.issueId == 0) {
            revert InvalidCallData();
        }
    }
    
    function _validateTierData(ItemTier[] calldata tiers) internal pure {
        if (tiers.length == 0) {
            revert InvalidCallData();
        }
        
        for (uint256 i = 0; i < tiers.length; i++) {
            if (tiers[i].tier == 0 || tiers[i].maxSupply == 0) {
                revert InvalidCallData();
            }
        }
    }
    
    function _validateVariantData(TierVariant[] calldata variants) internal pure {
        if (variants.length == 0) {
            revert InvalidCallData();
        }
        
        for (uint256 i = 0; i < variants.length; i++) {
            // Allow variant 0, but tier must be > 0
            if (variants[i].tier == 0) {
                revert InvalidCallData();
            }
        }
    }
    
    function _performVariantShuffle(
        uint256 collectionId,
        uint8 tier,
        uint256 tokenId,
        ItemTier storage itemTier
    ) internal view returns (uint8) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint8[] memory availableVariants = new uint8[](itemTier.variantsCount);
        uint256[] memory variantWeights = new uint256[](itemTier.variantsCount);
        uint256 totalWeight = 0;
        uint256 availableCount = 0;
        
        for (uint8 v = 1; v <= MAX_VARIANTS_PER_TIER && availableCount < itemTier.variantsCount; v++) {
            TierVariant storage variant = cs.tierVariants[collectionId][tier][v];
            if (variant.tier == tier && variant.maxSupply > 0 && variant.active) {
                uint256 minted = cs.hitVariantsCounters[collectionId][tier][v];
                if (minted < variant.maxSupply) {
                    uint256 available = variant.maxSupply - minted;
                    availableVariants[availableCount] = v;
                    variantWeights[availableCount] = available;
                    totalWeight += available;
                    availableCount++;
                }
            }
        }
        
        if (totalWeight == 0) {
            revert InsufficientVariantsAvailable();
        }
        
        uint256 randomValue = uint256(keccak256(abi.encodePacked(
            blockhash(block.number - 1), 
            tokenId,
            block.timestamp,
            block.prevrandao
        ))) % totalWeight;
        
        uint256 currentWeight = 0;
        for (uint256 i = 0; i < availableCount; i++) {
            currentWeight += variantWeights[i];
            if (randomValue < currentWeight) {
                return availableVariants[i];
            }
        }
        
        return availableVariants[0];
    }
}