// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibCollectionStorage} from "../libraries/LibCollectionStorage.sol";
import {CollectionType} from "../libraries/ModularAssetModel.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ConfigurationFacet - Complete System Configuration Management
 * @notice Unified configuration for system, pricing, and operational parameters
 * @dev Production-ready facet with comprehensive configuration and view functions
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 * @custom:version 4.1.0 - Complete production version
 */
contract ConfigurationFacet is AccessControlBase {
    
    // ==================== CONFIGURATION STRUCTS ====================
    
    struct SystemConfig {
        address biopodAddress;
        address chargepodAddress;
        address stakingSystemAddress;
        bool paused;
    }

    struct TreasuryConfig {
        address treasuryAddress;
        address treasuryCurrency;
    }

    struct ExchangeConfig {
        address basePriceFeed;
        address quotePriceFeed;
        bool isActive;
    }

    struct PricingConfig {
        uint256 collectionId;
        uint8 tier;
        uint256 regular;
        uint256 discounted;
        bool chargeNative;
        IERC20 currency;
        address beneficiary;
        bool onSale;
        bool isActive;
        bool useExchangeRate;
        uint256 maxMintsPerWallet;
    }

    struct MintingConfig {
        uint256 collectionId;
        uint8 tier;
        uint256 startTime;
        uint256 endTime;
        uint8 defaultVariant;
        uint256 maxMints;
        uint256 freeMints;
        bool isActive;
    }

    struct RollingConfig {
        uint256 reservationTimeSeconds;
        uint8 maxRerollsPerUser;
        uint256 randomMintCooldown;
        bool enabled;
    }

    struct CouponConfig {
        uint256 maxRollsPerCoupon;
        uint256 freeRollsPerCoupon;
        bool rateLimitingEnabled;
        uint256 cooldownBetweenRolls;
    }

    struct CouponCollectionConfig {
        uint256 collectionId;
        address collectionAddress;
        address stakingContract;
        uint8[] excludedVariants;
        bool requireStaking;
        bool active;
        bool allowSelfRolling;  // true = allows variant 0 (self-rolling), false = requires variant > 0 (coupon)
    }

    // ==================== EVENTS ====================
    
    event SystemConfigUpdated(string indexed component, address indexed oldAddress, address indexed newAddress);
    event SystemPaused(bool paused);
    event TreasuryConfigured(address indexed treasuryAddress, address indexed currency);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OperatorUpdated(address indexed operator, bool indexed authorized);
    event CurrencyExchangeConfigured(address indexed baseFeed, address indexed quoteFeed, bool active);
    event ExchangeStatusChanged(bool active);
    event PricingConfigured(uint256 indexed collectionId, uint8 indexed tier, string pricingType, uint256 regular, uint256 discounted);
    event PricingStatusChanged(uint256 indexed collectionId, uint8 indexed tier, string pricingType, bool isActive);
    event RollingConfigured(uint256 reservationTime, uint8 maxRerolls, uint256 cooldown, bool enabled);
    event CouponConfigured(uint256 maxRolls, uint256 freeRolls, bool rateLimiting, uint256 cooldown);
    event CouponCollectionConfigured(uint256 indexed collectionId, address stakingContract, bool requireStaking);
    event MintingRollingAllowedChanged(uint256 indexed collectionId, uint8 indexed tier, bool allowed);

    // ==================== ERRORS ====================
    
    error InvalidAddress();
    error InvalidConfiguration();
    error NotOwnerOrOperator();
    error AlreadyAuthorized();
    error InvalidPriceFeedConfiguration();
    error ExchangeNotConfigured();
    error InvalidDecimals();
    error ParameterOutOfRange();
    error InvalidPricingConfiguration();
    error CurrencyNotSet();
    error BeneficiaryNotSet();
    error InvalidTimeRange();
    error InvalidCollectionType(CollectionType actual, CollectionType expected);
    
    // ==================== CONSTANTS ====================
    
    uint8 private constant MAX_FEED_DECIMALS = 18;
    uint256 private constant MAX_RESERVATION_TIME = 7 days;
    uint8 private constant MAX_REROLLS = 50;
    uint256 private constant MAX_COOLDOWN = 1 days;
    uint256 private constant MAX_ROLLS_PER_COUPON = 1000;
    
    // ==================== SYSTEM CONFIGURATION ====================
    
    function updateSystemConfiguration(
        SystemConfig calldata config
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (config.biopodAddress != address(0) && config.biopodAddress != cs.biopodAddress) {
            address oldAddress = cs.biopodAddress;
            cs.biopodAddress = config.biopodAddress;
            emit SystemConfigUpdated("Biopod", oldAddress, config.biopodAddress);
        }
        
        if (config.chargepodAddress != address(0) && config.chargepodAddress != cs.chargepodAddress) {
            address oldAddress = cs.chargepodAddress;
            cs.chargepodAddress = config.chargepodAddress;
            emit SystemConfigUpdated("Chargepod", oldAddress, config.chargepodAddress);
        }
        
        if (config.stakingSystemAddress != address(0) && config.stakingSystemAddress != cs.stakingSystemAddress) {
            address oldAddress = cs.stakingSystemAddress;
            cs.stakingSystemAddress = config.stakingSystemAddress;
            emit SystemConfigUpdated("StakingSystem", oldAddress, config.stakingSystemAddress);
        }

        if (cs.paused != config.paused) {
            cs.paused = config.paused;
            emit SystemPaused(config.paused);
        }
    }

    function configureTreasury(TreasuryConfig calldata config) external onlyAuthorized whenNotPaused {
        if (config.treasuryAddress == address(0) || config.treasuryCurrency == address(0)) {
            revert InvalidConfiguration();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        cs.systemTreasury.treasuryAddress = config.treasuryAddress;
        cs.systemTreasury.treasuryCurrency = config.treasuryCurrency;
        
        emit TreasuryConfigured(config.treasuryAddress, config.treasuryCurrency);
    }

    function setPaused(bool paused) external onlyAuthorized {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        cs.paused = paused;
        
        emit SystemPaused(paused);
    }

    // ==================== CURRENCY EXCHANGE CONFIGURATION ====================
    
    function configureCurrencyExchange(
        ExchangeConfig calldata config
    ) external onlyAuthorized whenNotPaused {
        if (config.basePriceFeed == address(0) || config.quotePriceFeed == address(0)) {
            revert InvalidPriceFeedConfiguration();
        }
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        (uint8 baseDecimals, uint8 quoteDecimals) = _validatePriceFeeds(config.basePriceFeed, config.quotePriceFeed);
        
        LibCollectionStorage.CurrencyExchange storage exchange = cs.currencyExchange;
        exchange.basePriceFeed = AggregatorV3Interface(config.basePriceFeed);
        exchange.quotePriceFeed = AggregatorV3Interface(config.quotePriceFeed);
        exchange.baseDecimals = baseDecimals;
        exchange.quoteDecimals = quoteDecimals;
        exchange.lastUpdateTime = block.timestamp;
        exchange.isActive = config.isActive;
        
        emit CurrencyExchangeConfigured(config.basePriceFeed, config.quotePriceFeed, config.isActive);
    }
    
    function setExchangeActive(bool active) external onlyAuthorized whenNotPaused {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (active && (address(cs.currencyExchange.basePriceFeed) == address(0) || 
                      address(cs.currencyExchange.quotePriceFeed) == address(0))) {
            revert ExchangeNotConfigured();
        }
        
        cs.currencyExchange.isActive = active;
        cs.currencyExchange.lastUpdateTime = block.timestamp;
        
        emit ExchangeStatusChanged(active);
    }
    
    // ==================== PRICING CONFIGURATION ====================
    
    function configureMinting(
        MintingConfig memory config,
        PricingConfig calldata pricingConfig
    ) public onlyAuthorized whenNotPaused validInternalCollection(config.collectionId) {
        
        _validateMintingConfig(config);
        _validatePricingConfig(pricingConfig);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.collections[config.collectionId].collectionType != CollectionType.Main && 
            cs.collections[config.collectionId].collectionType != CollectionType.Augment) {

            revert InvalidCollectionType(cs.collections[config.collectionId].collectionType, CollectionType.Main);
        }
        
        LibCollectionStorage.MintingConfig storage mintConfig = cs.mintingConfigs[config.collectionId][config.tier];
        mintConfig.startTime = config.startTime;
        mintConfig.endTime = config.endTime;
        mintConfig.defaultVariant = config.defaultVariant;
        mintConfig.maxMints = config.maxMints;
        mintConfig.isActive = config.isActive;
        
        LibCollectionStorage.MintPricing storage pricing = cs.mintPricingByTier[config.collectionId][config.tier];
        pricing.regular = pricingConfig.regular;
        pricing.discounted = pricingConfig.discounted;
        pricing.chargeNative = pricingConfig.chargeNative;
        pricing.currency = pricingConfig.currency;
        pricing.beneficiary = pricingConfig.beneficiary;
        pricing.onSale = pricingConfig.onSale;
        pricing.isActive = pricingConfig.isActive;
        pricing.freeMints = config.freeMints;
        pricing.useExchangeRate = pricingConfig.useExchangeRate;
        pricing.maxMints = config.maxMints;
        pricing.maxMintsPerWallet = pricingConfig.maxMintsPerWallet; 
        
        emit PricingConfigured(config.collectionId, config.tier, "minting", pricingConfig.regular, pricingConfig.discounted);
    }

    function configureRollingPricing(
        PricingConfig calldata pricingConfig
    ) public onlyAuthorized whenNotPaused validInternalCollection(pricingConfig.collectionId) {
        
        _validatePricingConfig(pricingConfig);
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.collections[pricingConfig.collectionId].collectionType != CollectionType.Main && 
            cs.collections[pricingConfig.collectionId].collectionType != CollectionType.Augment) {
            revert InvalidCollectionType(cs.collections[pricingConfig.collectionId].collectionType, CollectionType.Main);
        }
        
        LibCollectionStorage.RollingPricing storage pricing = cs.rollingPricingByTier[pricingConfig.collectionId][pricingConfig.tier];
        pricing.regular = pricingConfig.regular;
        pricing.discounted = pricingConfig.discounted;
        pricing.chargeNative = pricingConfig.chargeNative;
        pricing.currency = pricingConfig.currency;
        pricing.beneficiary = pricingConfig.beneficiary;
        pricing.onSale = pricingConfig.onSale;
        pricing.isActive = pricingConfig.isActive;
        pricing.useExchangeRate = pricingConfig.useExchangeRate;
        
        emit PricingConfigured(pricingConfig.collectionId, pricingConfig.tier, "rolling", pricingConfig.regular, pricingConfig.discounted);
    }

    function configureAssignmentPricing(
        PricingConfig calldata pricingConfig
    ) public onlyAuthorized whenNotPaused validInternalCollection(pricingConfig.collectionId) {
        
        _validatePricingConfig(pricingConfig);
        
        LibCollectionStorage.AssignmentPricing storage pricing = LibCollectionStorage.collectionStorage().assignmentPricingByTier[pricingConfig.collectionId][pricingConfig.tier];
        pricing.regular = pricingConfig.regular;
        pricing.discounted = pricingConfig.discounted;
        pricing.currency = pricingConfig.currency;
        pricing.beneficiary = pricingConfig.beneficiary;
        pricing.onSale = pricingConfig.onSale;
        pricing.isActive = pricingConfig.isActive;
        
        emit PricingConfigured(pricingConfig.collectionId, pricingConfig.tier, "assignment", pricingConfig.regular, pricingConfig.discounted);
    }

    /**
     * @notice Configure self-reset pricing using existing ControlFee pattern
     */
    function configureSelfResetPricing(
        PricingConfig calldata pricingConfig
    ) public onlyAuthorized whenNotPaused validCollection(pricingConfig.collectionId) {
        _validatePricingConfig(pricingConfig);

        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.SelfResetPricing storage pricing = cs.selfResetPricingByTier[pricingConfig.collectionId][pricingConfig.tier];
        
        pricing.resetFee = LibCollectionStorage.ControlFee({
            currency: address(pricingConfig.currency),
            amount: pricingConfig.regular,
            beneficiary: pricingConfig.beneficiary
        });

        pricing.isActive = pricingConfig.isActive;
        
        emit PricingConfigured(pricingConfig.collectionId, pricingConfig.tier, "reset", pricingConfig.regular, pricingConfig.discounted);
    }

    function batchConfigurePricing(
        string calldata pricingType,
        PricingConfig[] calldata configs
    ) external onlyAuthorized whenNotPaused nonReentrant rateLimited(20, 1 hours) {
        
        if (configs.length == 0 || configs.length > 50) {
            revert InvalidConfiguration();
        }

        bytes32 typeHash = keccak256(bytes(pricingType));
        
        for (uint256 i = 0; i < configs.length; i++) {
            if (typeHash == keccak256("minting")) {
                MintingConfig memory mintConfig = MintingConfig({
                    collectionId: configs[i].collectionId,
                    tier: configs[i].tier,
                    startTime: block.timestamp,
                    endTime: block.timestamp + 30 days,
                    defaultVariant: 0,
                    maxMints: 10000,
                    freeMints: 0,
                    isActive: configs[i].isActive
                });
                configureMinting(mintConfig, configs[i]);
            } else if (typeHash == keccak256("rolling")) {
                configureRollingPricing(configs[i]);
            } else if (typeHash == keccak256("assignment")) {
                configureAssignmentPricing(configs[i]);
            } else if (typeHash == keccak256("reset")) {
                configureSelfResetPricing(configs[i]);
            } else {
                revert InvalidConfiguration();
            }
        }
    }

    function setPricingActive(
        uint256 collectionId, 
        uint8 tier, 
        string calldata pricingType, 
        bool isActive
    ) external onlyAuthorized whenNotPaused validInternalCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        bytes32 typeHash = keccak256(bytes(pricingType));
        
        if (typeHash == keccak256("minting")) {
            cs.mintingConfigs[collectionId][tier].isActive = isActive;
            cs.mintPricingByTier[collectionId][tier].isActive = isActive;
        } else if (typeHash == keccak256("rolling")) {
            cs.rollingPricingByTier[collectionId][tier].isActive = isActive;
        } else if (typeHash == keccak256("assignment")) {
            cs.assignmentPricingByTier[collectionId][tier].isActive = isActive;
        } else if (typeHash == keccak256("reset")) {
            cs.selfResetPricingByTier[collectionId][tier].isActive = isActive;
        }  else {
            revert InvalidConfiguration();
        }
        
        emit PricingStatusChanged(collectionId, tier, pricingType, isActive);
    }

    /**
     * @notice Enable or disable rolling minting for a collection tier
     * @dev Controls the allowRolling flag in MintingConfig, required for rolling to work
     * @param collectionId The collection ID
     * @param tier The tier level
     * @param allowed Whether rolling should be allowed
     */
    function setMintingRollingAllowed(
        uint256 collectionId,
        uint8 tier,
        bool allowed
    ) external onlyAuthorized whenNotPaused validInternalCollection(collectionId) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        cs.mintingConfigs[collectionId][tier].allowRolling = allowed;

        emit MintingRollingAllowedChanged(collectionId, tier, allowed);
    }

    // ==================== SYSTEM PARAMETERS CONFIGURATION ====================

    function configureRollingSystem(
        RollingConfig calldata config
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        _validateRollingConfig(config);

        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.RollingConfiguration storage rollingConfig = cs.rollingConfiguration;
        
        rollingConfig.reservationTimeSeconds = config.reservationTimeSeconds;
        rollingConfig.maxRerollsPerUser = config.maxRerollsPerUser;
        rollingConfig.randomMintCooldown = config.randomMintCooldown;
        rollingConfig.enabled = config.enabled;
        
        emit RollingConfigured(config.reservationTimeSeconds, config.maxRerollsPerUser, config.randomMintCooldown, config.enabled);
    }

    function configureCouponSystem(
        CouponConfig calldata config
    ) external onlyAuthorized whenNotPaused nonReentrant {
        
        _validateCouponConfig(config);

        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.CouponConfiguration storage couponConfig = cs.couponConfiguration;
        
        couponConfig.maxRollsPerCoupon = config.maxRollsPerCoupon;
        couponConfig.freeRollsPerCoupon = config.freeRollsPerCoupon;
        couponConfig.rateLimitingEnabled = config.rateLimitingEnabled;
        couponConfig.cooldownBetweenRolls = config.cooldownBetweenRolls;
        
        emit CouponConfigured(config.maxRollsPerCoupon, config.freeRollsPerCoupon, config.rateLimitingEnabled, config.cooldownBetweenRolls);
    }

    function configureCouponCollection(
        CouponCollectionConfig calldata config
    ) external onlyAuthorized whenNotPaused nonReentrant validCollection(config.collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        (address collectionAddress, , bool exists) = LibCollectionStorage.getCollectionInfo(config.collectionId);
        if (!exists && (config.collectionAddress == address(0))) {
            revert CollectionNotFound(config.collectionId);
        }
        
        LibCollectionStorage.CouponCollection storage couponCollection = cs.couponCollections[config.collectionId];
        couponCollection.collectionAddress = (config.collectionAddress != address(0)) ? config.collectionAddress : collectionAddress;
        couponCollection.collectionId = config.collectionId;
        couponCollection.stakingContract = config.stakingContract;
        couponCollection.stakingIntegration = config.stakingContract != address(0);
        couponCollection.requireStaking = config.requireStaking;
        couponCollection.excludedVariants = config.excludedVariants;
        couponCollection.active = config.active;
        couponCollection.allowSelfRolling = config.allowSelfRolling;

        emit CouponCollectionConfigured(config.collectionId, config.stakingContract, config.requireStaking);
    }

    // ==================== ACCESS CONTROL ====================
    
    function setOperator(address operator, bool authorized) external onlyAuthorized whenNotPaused {
        if (operator == address(0)) revert InvalidAddress();
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (cs.operators[operator] == authorized) {
            if (authorized) {
                revert AlreadyAuthorized();
            } else {
                revert NotAuthorized();
            }
        }
        
        cs.operators[operator] = authorized;
        
        emit OperatorUpdated(operator, authorized);
    } 
    
    function transferOwnership(address newOwner) external {
        if (newOwner == address(0)) revert InvalidAddress();
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (LibMeta.msgSender() != cs.contractOwner) revert NotOwnerOrOperator();
        
        address oldOwner = cs.contractOwner;
        cs.contractOwner = newOwner;
        
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // ==================== ADMIN UTILITIES ====================

    function emergencyResetCoupon(
        uint256 collectionId, 
        uint256 tokenId, 
        bool completeReset
    ) external onlyAuthorized whenNotPaused validCollection(collectionId) {
        
        uint256 combinedId = (collectionId << 128) | tokenId;
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (completeReset) {
            delete cs.rollCouponsByTokenId[combinedId];
        } else {
            LibCollectionStorage.RollCoupon storage coupon = cs.rollCouponsByTokenId[combinedId];
            coupon.usedRolls = 0;
            coupon.freeRollsUsed = 0;
            coupon.lastRollTime = 0;
        }
    }

    function updateSupplyTracking(
        uint256 collectionId, 
        uint256 newSupply
    ) external onlySystem validInternalCollection(collectionId) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.CollectionData storage collection = cs.collections[collectionId];
        
        collection.currentSupply = newSupply;
        collection.lastUpdateTime = block.timestamp;
    }

    // ==================== VIEW FUNCTIONS ====================

    function getSystemConfiguration() external view returns (
        SystemConfig memory systemConfig,
        TreasuryConfig memory treasuryConfig,
        ExchangeConfig memory exchangeConfig
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        systemConfig = SystemConfig({
            biopodAddress: cs.biopodAddress,
            chargepodAddress: cs.chargepodAddress,
            stakingSystemAddress: cs.stakingSystemAddress,
            paused: cs.paused
        });
        
        treasuryConfig = TreasuryConfig({
            treasuryAddress: cs.systemTreasury.treasuryAddress,
            treasuryCurrency: cs.systemTreasury.treasuryCurrency
        });
        
        exchangeConfig = ExchangeConfig({
            basePriceFeed: address(cs.currencyExchange.basePriceFeed),
            quotePriceFeed: address(cs.currencyExchange.quotePriceFeed),
            isActive: cs.currencyExchange.isActive
        });
    }

    function getPricingConfiguration(
        uint256 collectionId,
        uint8 tier,
        string calldata pricingType
    ) external view returns (PricingConfig memory config, bool exists) {
        
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        bytes32 typeHash = keccak256(bytes(pricingType));
        
        if (typeHash == keccak256("minting")) {
            LibCollectionStorage.MintPricing storage pricing = cs.mintPricingByTier[collectionId][tier];
            if (address(pricing.currency) != address(0) || pricing.chargeNative) {
                config = PricingConfig({
                    collectionId: collectionId,
                    tier: tier,
                    regular: pricing.regular,
                    discounted: pricing.discounted,
                    chargeNative: pricing.chargeNative,
                    currency: pricing.currency,
                    beneficiary: pricing.beneficiary,
                    onSale: pricing.onSale,
                    isActive: pricing.isActive,
                    useExchangeRate: pricing.useExchangeRate,
                    maxMintsPerWallet: pricing.maxMintsPerWallet
                });
                exists = true;
            }
        } else if (typeHash == keccak256("rolling")) {
            LibCollectionStorage.RollingPricing storage pricing = cs.rollingPricingByTier[collectionId][tier];
            if (address(pricing.currency) != address(0) || pricing.chargeNative) {
                config = PricingConfig({
                    collectionId: collectionId,
                    tier: tier,
                    regular: pricing.regular,
                    discounted: pricing.discounted,
                    chargeNative: pricing.chargeNative,
                    currency: pricing.currency,
                    beneficiary: pricing.beneficiary,
                    onSale: pricing.onSale,
                    isActive: pricing.isActive,
                    useExchangeRate: pricing.useExchangeRate,
                    maxMintsPerWallet: 0
                });
                exists = true;
            }
        } else if (typeHash == keccak256("assignment")) {
            LibCollectionStorage.AssignmentPricing storage pricing = cs.assignmentPricingByTier[collectionId][tier];
            if (address(pricing.currency) != address(0)) {
                config = PricingConfig({
                    collectionId: collectionId,
                    tier: tier,
                    regular: pricing.regular,
                    discounted: pricing.discounted,
                    chargeNative: false,
                    currency: pricing.currency,
                    beneficiary: pricing.beneficiary,
                    onSale: pricing.onSale,
                    isActive: pricing.isActive,
                    useExchangeRate: false,
                    maxMintsPerWallet: 0
                });
                exists = true;
            }
        }
    }

    function getMintingConfiguration(
        uint256 collectionId,
        uint8 tier
    ) external view returns (MintingConfig memory config, bool exists) {
        
        LibCollectionStorage.MintingConfig storage mintConfig = LibCollectionStorage.collectionStorage().mintingConfigs[collectionId][tier];
        
        if (mintConfig.maxMints > 0) {
            LibCollectionStorage.MintPricing storage pricing = LibCollectionStorage.collectionStorage().mintPricingByTier[collectionId][tier];
            
            config = MintingConfig({
                collectionId: collectionId,
                tier: tier,
                startTime: mintConfig.startTime,
                endTime: mintConfig.endTime,
                defaultVariant: mintConfig.defaultVariant,
                maxMints: mintConfig.maxMints,
                freeMints: pricing.freeMints,
                isActive: mintConfig.isActive
            });
            exists = true;
        }
    }

    /**
     * @notice Get self-reset pricing configuration
     * @param collectionId Collection ID
     * @param tier Tier level
     * @return pricing Self-reset pricing configuration
     * @return isConfigured Whether self-reset is configured
     */
    function getSelfResetPricing(
        uint256 collectionId,
        uint8 tier
    ) external view returns (
        LibCollectionStorage.SelfResetPricing memory pricing,
        bool isConfigured
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        pricing = cs.selfResetPricingByTier[collectionId][tier];
        isConfigured = pricing.resetFee.currency != address(0);
    }

    function getSystemParameters() external view returns (
        RollingConfig memory rollingConfig,
        CouponConfig memory couponConfig
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        LibCollectionStorage.RollingConfiguration storage rolling = cs.rollingConfiguration;
        rollingConfig = RollingConfig({
            reservationTimeSeconds: rolling.reservationTimeSeconds,
            maxRerollsPerUser: rolling.maxRerollsPerUser,
            randomMintCooldown: rolling.randomMintCooldown,
            enabled: rolling.enabled
        });
        
        LibCollectionStorage.CouponConfiguration storage coupon = cs.couponConfiguration;
        couponConfig = CouponConfig({
            maxRollsPerCoupon: coupon.maxRollsPerCoupon,
            freeRollsPerCoupon: coupon.freeRollsPerCoupon,
            rateLimitingEnabled: coupon.rateLimitingEnabled,
            cooldownBetweenRolls: coupon.cooldownBetweenRolls
        });
    }

    function getComponentStatus(string calldata component) external view returns (
        bool configured,
        address componentAddress
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        bytes32 componentHash = keccak256(bytes(component));
        
        if (componentHash == keccak256("biopod")) {
            componentAddress = cs.biopodAddress;
        } else if (componentHash == keccak256("chargepod")) {
            componentAddress = cs.chargepodAddress;
        } else if (componentHash == keccak256("staking")) {
            componentAddress = cs.stakingSystemAddress;
        } else if (componentHash == keccak256("treasury")) {
            componentAddress = cs.systemTreasury.treasuryAddress;
        }
        
        configured = componentAddress != address(0);
    }

    function isMintingActive(uint256 collectionId, uint8 tier) external view returns (
        bool active, 
        string memory reason, 
        uint256 timeRemaining
    ) {
        LibCollectionStorage.MintingConfig storage config = LibCollectionStorage.collectionStorage().mintingConfigs[collectionId][tier];
        LibCollectionStorage.MintPricing storage pricing = LibCollectionStorage.collectionStorage().mintPricingByTier[collectionId][tier];
        
        if (!config.isActive || !pricing.isActive) {
            return (false, "Minting disabled", 0);
        }
        
        if (block.timestamp < config.startTime) {
            return (false, "Not started", config.startTime - block.timestamp);
        }
        
        if (block.timestamp > config.endTime) {
            return (false, "Ended", 0);
        }
        
        if (config.currentMints >= config.maxMints) {
            return (false, "Sold out", 0);
        }
        
        return (true, "Active", 0);
    }

    function getAuthorizationStatus(address account) external view returns (
        bool isOwner,
        bool isSysOperator,
        bool isAuthorized
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        isOwner = account == cs.contractOwner;
        isSysOperator = cs.operators[account];
        isAuthorized = isOwner || isSysOperator;
    }

    function testCurrencyExchange(uint256 listPrice) external view returns (
        bool success,
        uint256 derivedPrice,
        uint80[2] memory roundIds
    ) {
        if (!LibCollectionStorage.isExchangeConfigured()) {
            return (false, 0, [uint80(0), uint80(0)]);
        }
        
        (derivedPrice, roundIds) = LibCollectionStorage.derivePriceFromExchange(listPrice, [uint80(0), uint80(0)]);
        if (derivedPrice > 0) {
            return (true, derivedPrice, roundIds);
        } else {
            return (false, 0, [uint80(0), uint80(0)]);
        }
    }

    // ==================== ADDITIONAL VIEW FUNCTIONS ====================

    function getAllPricingForCollection(uint256 collectionId) external view returns (
        PricingConfig[] memory mintingConfigs,
        PricingConfig[] memory rollingConfigs,
        PricingConfig[] memory assignmentConfigs
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 mintingCount = 0;
        uint256 rollingCount = 0;
        uint256 assignmentCount = 0;
        
        for (uint8 tier = 1; tier <= 10; tier++) {
            if (address(cs.mintPricingByTier[collectionId][tier].currency) != address(0) || 
                cs.mintPricingByTier[collectionId][tier].chargeNative) {
                mintingCount++;
            }
            if (address(cs.rollingPricingByTier[collectionId][tier].currency) != address(0) || 
                cs.rollingPricingByTier[collectionId][tier].chargeNative) {
                rollingCount++;
            }
            if (address(cs.assignmentPricingByTier[collectionId][tier].currency) != address(0)) {
                assignmentCount++;
            }
        }
        
        mintingConfigs = new PricingConfig[](mintingCount);
        rollingConfigs = new PricingConfig[](rollingCount);
        assignmentConfigs = new PricingConfig[](assignmentCount);
        
        uint256 mIndex = 0;
        uint256 rIndex = 0;
        uint256 aIndex = 0;
        
        for (uint8 tier = 1; tier <= 10; tier++) {
            (PricingConfig memory mintConfig, bool mintExists) = this.getPricingConfiguration(collectionId, tier, "minting");
            if (mintExists) {
                mintingConfigs[mIndex] = mintConfig;
                mIndex++;
            }
            
            (PricingConfig memory rollConfig, bool rollExists) = this.getPricingConfiguration(collectionId, tier, "rolling");
            if (rollExists) {
                rollingConfigs[rIndex] = rollConfig;
                rIndex++;
            }
            
            (PricingConfig memory assignConfig, bool assignExists) = this.getPricingConfiguration(collectionId, tier, "assignment");
            if (assignExists) {
                assignmentConfigs[aIndex] = assignConfig;
                aIndex++;
            }
        }
    }

    function getCouponCollectionConfig(uint256 collectionId) external view returns (
        CouponCollectionConfig memory config,
        bool exists
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        LibCollectionStorage.CouponCollection storage coupon = cs.couponCollections[collectionId];
        
        if (coupon.collectionAddress != address(0)) {
            config = CouponCollectionConfig({
                collectionId: collectionId,
                collectionAddress: coupon.collectionAddress,
                stakingContract: coupon.stakingContract,
                excludedVariants: coupon.excludedVariants,
                requireStaking: coupon.requireStaking,
                active: coupon.active,
                allowSelfRolling: coupon.allowSelfRolling
            });
            exists = true;
        }
    }

    function getAllCouponCollections() external view returns (
        CouponCollectionConfig[] memory configs
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (cs.couponCollections[i].collectionAddress != address(0)) {
                count++;
            }
        }
        
        configs = new CouponCollectionConfig[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            (CouponCollectionConfig memory config, bool exists) = this.getCouponCollectionConfig(i);
            if (exists) {
                configs[index] = config;
                index++;
            }
        }
    }

    function getSystemStatus() external view returns (
        string[] memory components,
        bool[] memory configured
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        components = new string[](5);
        configured = new bool[](5);
        
        components[0] = "Biopod";
        configured[0] = cs.biopodAddress != address(0);
        
        components[1] = "Chargepod";
        configured[1] = cs.chargepodAddress != address(0);
        
        components[2] = "Staking";  
        configured[2] = cs.stakingSystemAddress != address(0);
        
        components[3] = "Treasury";
        configured[3] = cs.systemTreasury.treasuryAddress != address(0);
        
        components[4] = "Exchange";
        configured[4] = address(cs.currencyExchange.basePriceFeed) != address(0);
    }

    function getPricingByType(string calldata pricingType) external view returns (
        uint256[] memory collectionIds,
        uint8[] memory tiers
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        bytes32 typeHash = keccak256(bytes(pricingType));
        
        uint256 count = 0;
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.collectionExists(i)) {
                for (uint8 tier = 1; tier <= 10; tier++) {
                    if (_hasPricingType(i, tier, typeHash)) {
                        count++;
                    }
                }
            }
        }
        
        collectionIds = new uint256[](count);
        tiers = new uint8[](count);
        
        uint256 index = 0;
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.collectionExists(i)) {
                for (uint8 tier = 1; tier <= 10; tier++) {
                    if (_hasPricingType(i, tier, typeHash)) {
                        collectionIds[index] = i;
                        tiers[index] = tier;
                        index++;
                    }
                }
            }
        }
    }

    function getActiveMintings() external view returns (
        uint256[] memory collectionIds,
        uint8[] memory tiers
    ) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        uint256 count = 0;
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.collectionExists(i)) {
                for (uint8 tier = 1; tier <= 10; tier++) {
                    if (cs.mintingConfigs[i][tier].isActive && cs.mintPricingByTier[i][tier].isActive) {
                        (bool isActive,,) = this.isMintingActive(i, tier);
                        if (isActive) count++;
                    }
                }
            }
        }
        
        collectionIds = new uint256[](count);
        tiers = new uint8[](count);
        
        uint256 index = 0;
        for (uint256 i = 1; i < cs.collectionCounter; i++) {
            if (LibCollectionStorage.collectionExists(i)) {
                for (uint8 tier = 1; tier <= 10; tier++) {
                    if (cs.mintingConfigs[i][tier].isActive && cs.mintPricingByTier[i][tier].isActive) {
                        (bool isActive,,) = this.isMintingActive(i, tier);
                        if (isActive) {
                            collectionIds[index] = i;
                            tiers[index] = tier;
                            index++;
                        }
                    }
                }
            }
        }
    }

    function isOperator(address account) external view returns (bool) {
        return LibCollectionStorage.collectionStorage().operators[account];
    }

    // ==================== INTERNAL VALIDATION FUNCTIONS ====================
    
    function _validatePriceFeeds(
        address basePriceFeed, 
        address quotePriceFeed
    ) internal view returns (uint8 baseDecimals, uint8 quoteDecimals) {
        
        AggregatorV3Interface baseAggregator = AggregatorV3Interface(basePriceFeed);
        AggregatorV3Interface quoteAggregator = AggregatorV3Interface(quotePriceFeed);
        
        try baseAggregator.decimals() returns (uint8 decimals) {
            if (decimals > MAX_FEED_DECIMALS) revert InvalidDecimals();
            baseDecimals = decimals;
        } catch {
            revert InvalidPriceFeedConfiguration();
        }
        
        try quoteAggregator.decimals() returns (uint8 decimals) {
            if (decimals > MAX_FEED_DECIMALS) revert InvalidDecimals();
            quoteDecimals = decimals;
        } catch {
            revert InvalidPriceFeedConfiguration();
        }
        
        try baseAggregator.latestRoundData() returns (uint80, int256 price, uint256, uint256, uint80) {
            if (price <= 0) revert InvalidPriceFeedConfiguration();
        } catch {
            revert InvalidPriceFeedConfiguration();
        }
        
        try quoteAggregator.latestRoundData() returns (uint80, int256 price, uint256, uint256, uint80) {
            if (price <= 0) revert InvalidPriceFeedConfiguration();
        } catch {
            revert InvalidPriceFeedConfiguration();
        }
    }
    
    function _validateMintingConfig(MintingConfig memory config) internal pure {
        if (config.startTime >= config.endTime) revert InvalidTimeRange();
        if (config.maxMints == 0) revert InvalidConfiguration();
    }
    
    function _validatePricingConfig(PricingConfig calldata config) internal pure {
        if (config.beneficiary == address(0)) revert BeneficiaryNotSet();
        if (!config.chargeNative && address(config.currency) == address(0)) revert CurrencyNotSet();
        if (config.regular == 0 && config.discounted == 0) revert InvalidPricingConfiguration();
    }

    function _validateRollingConfig(RollingConfig calldata config) internal pure {
        if (config.reservationTimeSeconds == 0 || config.reservationTimeSeconds > MAX_RESERVATION_TIME) {
            revert ParameterOutOfRange();
        }
        if (config.maxRerollsPerUser > MAX_REROLLS) {
            revert ParameterOutOfRange();
        }
        if (config.randomMintCooldown > MAX_COOLDOWN) {
            revert ParameterOutOfRange();
        }
    }
    
    function _validateCouponConfig(CouponConfig calldata config) internal pure {
        if (config.maxRollsPerCoupon > MAX_ROLLS_PER_COUPON) {
            revert ParameterOutOfRange();
        }
        if (config.freeRollsPerCoupon > config.maxRollsPerCoupon) {
            revert ParameterOutOfRange();
        }
        if (config.cooldownBetweenRolls > MAX_COOLDOWN) {
            revert ParameterOutOfRange();
        }
    }

    function _hasPricingType(uint256 collectionId, uint8 tier, bytes32 typeHash) internal view returns (bool) {
        LibCollectionStorage.CollectionStorage storage cs = LibCollectionStorage.collectionStorage();
        
        if (typeHash == keccak256("minting")) {
            return address(cs.mintPricingByTier[collectionId][tier].currency) != address(0) || 
                   cs.mintPricingByTier[collectionId][tier].chargeNative;
        } else if (typeHash == keccak256("rolling")) {
            return address(cs.rollingPricingByTier[collectionId][tier].currency) != address(0) || 
                   cs.rollingPricingByTier[collectionId][tier].chargeNative;
        } else if (typeHash == keccak256("assignment")) {
            return address(cs.assignmentPricingByTier[collectionId][tier].currency) != address(0);
        }
        
        return false;
    }
}