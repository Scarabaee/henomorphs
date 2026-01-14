// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {LibMeta} from "../../shared/libraries/LibMeta.sol";
import {LibColonyWarsStorage} from "../libraries/LibColonyWarsStorage.sol";
import {LibHenomorphsStorage} from "../libraries/LibHenomorphsStorage.sol";
import {LibFeeCollection} from "../libraries/LibFeeCollection.sol";
import {AccessControlBase} from "./AccessControlBase.sol";
import {ColonyHelper} from "../libraries/ColonyHelper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AccessHelper} from "../libraries/AccessHelper.sol";

/**
 * @title TerritoryMarketplaceFacet
 * @notice Territory trading and marketplace functionality for Colony Wars
 * @dev Handles territory listings, direct purchases, and offers system
 */
contract TerritoryMarketplaceFacet is AccessControlBase {

    uint256 constant DEFAULT_MAX_TERRITORY_PER_COLONY = 6;
    
    // Events
    event TerritoryListed(uint256 indexed territoryId, bytes32 indexed seller, uint256 askPrice, uint32 expiryTime);
    event TerritoryListingCancelled(uint256 indexed territoryId, bytes32 indexed seller);
    event TerritoryOfferMade(bytes32 indexed offerId, uint256 indexed territoryId, bytes32 indexed buyer, uint256 offerPrice);
    event TerritoryOfferCancelled(bytes32 indexed offerId, bytes32 indexed buyer, uint256 refundAmount);
    event TerritoryOfferAccepted(bytes32 indexed offerId, uint256 indexed territoryId, bytes32 seller, bytes32 buyer, uint256 price);
    event TerritorySold(uint256 indexed territoryId, bytes32 indexed seller, bytes32 indexed buyer, uint256 price);
    event TerritoryLost(uint256 indexed territoryId, bytes32 indexed previousOwner, string reason);
    event TerritoryCardDeactivated(uint256 indexed territoryId, uint256 indexed cardTokenId);
    event TerritoryCardActivated(uint256 indexed territoryId, uint256 indexed cardTokenId, bytes32 indexed colony);
    
    // Custom errors
    error TerritoryNotFound();
    error TerritoryNotOwned();
    error AlreadyListed();
    error NotListed();
    error InvalidPrice();
    error InvalidExpiry();
    error ListingExpired();
    error OfferExpired();
    error OfferNotFound();
    error CannotBuyOwn();
    error TerritoryLimitExceeded();
    error TerritoryCardsNotConfigured();

    // ============================================================================
    // LISTING FUNCTIONS
    // ============================================================================

    /**
     * @notice List territory for sale
     * @param territoryId Territory to sell
     * @param askPrice Asking price in ZICO
     * @param durationDays How many days listing is valid (0 = no expiry)
     */
    function listTerritory(
        uint256 territoryId,
        uint256 askPrice,
        uint32 durationDays
    ) external whenNotPaused nonReentrant {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Validate territory ownership
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active || territory.controllingColony == bytes32(0)) {
            revert TerritoryNotFound();
        }
        
        if (!ColonyHelper.isColonyCreator(territory.controllingColony, hs.stakingSystemAddress)) {
            revert TerritoryNotOwned();
        }
        
        // Check if already listed
        if (cws.territoryListings[territoryId].active) {
            revert AlreadyListed();
        }
        
        // Validate price
        if (askPrice < 100 ether) {
            revert InvalidPrice();
        }
        
        // Validate expiry
        uint32 expiryTime = 0;
        if (durationDays > 0) {
            if (durationDays > 90) {
                revert InvalidExpiry();
            }
            expiryTime = uint32(block.timestamp) + (durationDays * 86400);
        }
        
        // Collect marketplace listing fee (configured YELLOW, burned)
        LibColonyWarsStorage.OperationFee storage listingFee = LibColonyWarsStorage.getOperationFee(LibColonyWarsStorage.FEE_LISTING);
        LibFeeCollection.processConfiguredFee(
            listingFee,
            LibMeta.msgSender(),
            "territory_marketplace_listing"
        );
        
        // Create listing
        cws.territoryListings[territoryId] = LibColonyWarsStorage.TerritoryListing({
            territoryId: territoryId,
            seller: territory.controllingColony,
            askPrice: askPrice,
            listedTime: uint32(block.timestamp),
            expiryTime: expiryTime,
            active: true
        });
        
        emit TerritoryListed(territoryId, territory.controllingColony, askPrice, expiryTime);
    }

    /**
     * @notice Cancel territory listing
     * @param territoryId Territory listing to cancel
     */
    function unlistTerritory(uint256 territoryId) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        LibColonyWarsStorage.TerritoryListing storage listing = cws.territoryListings[territoryId];
        if (!listing.active) {
            revert NotListed();
        }
        
        // Only seller can cancel
        if (!ColonyHelper.isColonyCreator(listing.seller, hs.stakingSystemAddress)) {
            revert TerritoryNotOwned();
        }
        
        bytes32 seller = listing.seller;
        listing.active = false;
        
        emit TerritoryListingCancelled(territoryId, seller);
    }

    // ============================================================================
    // PURCHASE FUNCTIONS
    // ============================================================================

    /**
     * @notice Buy territory directly at asking price
     * @param territoryId Territory to buy
     * @param buyerColony Buyer's colony
     */
    function purchaseTerritory(uint256 territoryId, bytes32 buyerColony) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Validate buyer authorization
        if (!ColonyHelper.isColonyCreator(buyerColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        // Get listing
        LibColonyWarsStorage.TerritoryListing storage listing = cws.territoryListings[territoryId];
        if (!listing.active) {
            revert NotListed();
        }
        
        // Check expiry
        if (listing.expiryTime > 0 && block.timestamp > listing.expiryTime) {
            listing.active = false;
            revert ListingExpired();
        }
        
        // Prevent self-purchase
        if (listing.seller == buyerColony) {
            revert CannotBuyOwn();
        }
        
        // Check buyer's territory limit
        uint256 currentTerritories = _countActiveColonyTerritories(buyerColony, cws);
        uint256 maxTerritories = cws.config.maxTerritoriesPerColony;
        if (maxTerritories == 0) {
            maxTerritories = DEFAULT_MAX_TERRITORY_PER_COLONY;
        }
        if (currentTerritories >= maxTerritories) {
            revert TerritoryLimitExceeded();
        }
        
        // Calculate payments: 90% to seller, 10% marketplace fee
        uint256 totalPrice = listing.askPrice;
        uint256 sellerAmount = (totalPrice * 90) / 100;
        uint256 marketplaceFee = totalPrice - sellerAmount;
        
        address currency = hs.chargeTreasury.treasuryCurrency;
        
        // Transfer payment to seller
        address sellerAddress = hs.colonyCreators[listing.seller];
        LibFeeCollection.collectFee(
            IERC20(currency),
            LibMeta.msgSender(),
            sellerAddress,
            sellerAmount,
            "territory_sale_payment"
        );
        
        // Transfer marketplace fee to treasury
        LibFeeCollection.collectFee(
            IERC20(currency),
            LibMeta.msgSender(),
            hs.chargeTreasury.treasuryAddress,
            marketplaceFee,
            "territory_marketplace_fee"
        );
        
        // Transfer territory ownership
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        bytes32 previousOwner = territory.controllingColony;
        
        _removeTerritoryFromColony(territoryId, previousOwner, cws);
        
        territory.controllingColony = buyerColony;
        territory.lastMaintenancePayment = uint32(block.timestamp);
        
        cws.colonyTerritories[buyerColony].push(territoryId);
        
        // Handle Territory Card transfer
        if (cws.contractAddresses.territoryCards != address(0)) {
            uint256 cardTokenId = cws.territoryToCard[territoryId];
            if (cardTokenId > 0) {
                // Deactivate card from old owner
                _deactivateTerritoryCard(territoryId, cardTokenId, cws);
                
                // Transfer NFT ownership from seller to buyer
                address buyerAddress = hs.colonyCreators[buyerColony];
                if (sellerAddress != address(0) && buyerAddress != address(0)) {
                    _transferTerritoryCard(cardTokenId, sellerAddress, buyerAddress, cws);
                }
                
                // Activate card for new owner
                _activateTerritoryCard(territoryId, cardTokenId, buyerColony, cws);
            }
        }
        
        // Deactivate listing
        listing.active = false;
        
        // Cancel all offers for this territory
        _cancelAllOffersForTerritory(territoryId, cws, hs);
        
        emit TerritorySold(territoryId, previousOwner, buyerColony, totalPrice);
    }

    // ============================================================================
    // OFFER FUNCTIONS
    // ============================================================================

    /**
     * @notice Make offer to buy territory
     * @param territoryId Territory to make offer on
     * @param buyerColony Buyer's colony
     * @param offerPrice Offer price in ZICO
     * @param durationDays How long offer is valid
     */
    function offerOnTerritory(
        uint256 territoryId,
        bytes32 buyerColony,
        uint256 offerPrice,
        uint32 durationDays
    ) external whenNotPaused nonReentrant returns (bytes32 offerId) {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        // Validate buyer authorization
        if (!ColonyHelper.isColonyCreator(buyerColony, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not colony controller");
        }
        
        // Validate territory exists and is owned
        LibColonyWarsStorage.Territory storage territory = cws.territories[territoryId];
        if (!territory.active || territory.controllingColony == bytes32(0)) {
            revert TerritoryNotFound();
        }
        
        // Cannot offer on own territory
        if (territory.controllingColony == buyerColony) {
            revert CannotBuyOwn();
        }
        
        // Validate offer price (minimum 100 ZICO)
        if (offerPrice < 100 ether) {
            revert InvalidPrice();
        }
        
        // Validate duration (1-90 days)
        if (durationDays == 0 || durationDays > 90) {
            revert InvalidExpiry();
        }
        
        // Check buyer's territory limit
        uint256 currentTerritories = _countActiveColonyTerritories(buyerColony, cws);
        uint256 maxTerritories = cws.config.maxTerritoriesPerColony;
        if (maxTerritories == 0) {
            maxTerritories = DEFAULT_MAX_TERRITORY_PER_COLONY;
        }
        if (currentTerritories >= maxTerritories) {
            revert TerritoryLimitExceeded();
        }
        
        // Lock ZICO for offer (escrow to treasury)
        address currency = hs.chargeTreasury.treasuryCurrency;
        LibFeeCollection.collectFee(
            IERC20(currency),
            LibMeta.msgSender(),
            hs.chargeTreasury.treasuryAddress,
            offerPrice,
            "territory_offer_escrow"
        );
        
        // Create offer
        cws.offerCounter++;
        offerId = keccak256(abi.encodePacked(territoryId, buyerColony, block.timestamp, cws.offerCounter));
        
        uint32 expiryTime = uint32(block.timestamp) + (durationDays * 86400);
        
        cws.territoryOffers[offerId] = LibColonyWarsStorage.TerritoryOffer({
            territoryId: territoryId,
            buyer: buyerColony,
            offerPrice: offerPrice,
            offerTime: uint32(block.timestamp),
            expiryTime: expiryTime,
            active: true
        });
        
        cws.territoryOfferIds[territoryId].push(offerId);
        
        emit TerritoryOfferMade(offerId, territoryId, buyerColony, offerPrice);
        
        return offerId;
    }

    /**
     * @notice Cancel offer and get refund
     * @param offerId Offer to cancel
     */
    function cancelTerritoryOffer(bytes32 offerId) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        LibColonyWarsStorage.TerritoryOffer storage offer = cws.territoryOffers[offerId];
        if (!offer.active) {
            revert OfferNotFound();
        }
        
        // Only buyer can cancel
        if (!ColonyHelper.isColonyCreator(offer.buyer, hs.stakingSystemAddress)) {
            revert AccessHelper.Unauthorized(LibMeta.msgSender(), "Not offer creator");
        }
        
        uint256 refundAmount = offer.offerPrice;
        bytes32 buyer = offer.buyer;

        // Deactivate offer
        offer.active = false;
        
        // Refund escrowed ZICO from treasury
        LibFeeCollection.transferFromTreasury(
            LibMeta.msgSender(),
            refundAmount,
            "territory_offer_refund"
        );
        
        // Remove from territory's offer list
        _removeOfferFromList(offer.territoryId, offerId, cws);
        
        emit TerritoryOfferCancelled(offerId, buyer, refundAmount);
    }

    /**
     * @notice Accept offer and sell territory
     * @param offerId Offer to accept
     */
    function acceptTerritoryOffer(bytes32 offerId) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        LibColonyWarsStorage.requireInitialized();
        
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        LibHenomorphsStorage.HenomorphsStorage storage hs = LibHenomorphsStorage.henomorphsStorage();
        
        LibColonyWarsStorage.TerritoryOffer storage offer = cws.territoryOffers[offerId];
        if (!offer.active) {
            revert OfferNotFound();
        }
        
        // Check expiry
        if (block.timestamp > offer.expiryTime) {
            offer.active = false;
            revert OfferExpired();
        }
        
        // Validate seller owns territory
        LibColonyWarsStorage.Territory storage territory = cws.territories[offer.territoryId];
        if (!territory.active || territory.controllingColony == bytes32(0)) {
            revert TerritoryNotFound();
        }
        
        if (!ColonyHelper.isColonyCreator(territory.controllingColony, hs.stakingSystemAddress)) {
            revert TerritoryNotOwned();
        }
        
        // Calculate payments: 90% to seller, 10% marketplace fee (stays in treasury)
        uint256 totalPrice = offer.offerPrice;
        uint256 sellerAmount = (totalPrice * 90) / 100;

        bytes32 seller = territory.controllingColony;
        bytes32 buyer = offer.buyer;
        
        // Transfer from treasury escrow to seller
        address sellerAddress = hs.colonyCreators[seller];
        LibFeeCollection.transferFromTreasury(
            sellerAddress,
            sellerAmount,
            "territory_sale_payment"
        );

        // Marketplace fee stays in treasury (no transfer needed)
        
        // Transfer territory ownership
        _removeTerritoryFromColony(offer.territoryId, seller, cws);
        
        territory.controllingColony = buyer;
        territory.lastMaintenancePayment = uint32(block.timestamp);
        
        cws.colonyTerritories[buyer].push(offer.territoryId);
        
        // Handle Territory Card transfer
        if (cws.contractAddresses.territoryCards != address(0)) {
            uint256 cardTokenId = cws.territoryToCard[offer.territoryId];
            if (cardTokenId > 0) {
                // Deactivate card from old owner
                _deactivateTerritoryCard(offer.territoryId, cardTokenId, cws);
                
                // Transfer NFT ownership from seller to buyer
                address buyerAddress = hs.colonyCreators[buyer];
                if (sellerAddress != address(0) && buyerAddress != address(0)) {
                    _transferTerritoryCard(cardTokenId, sellerAddress, buyerAddress, cws);
                }
                
                // Activate card for new owner
                _activateTerritoryCard(offer.territoryId, cardTokenId, buyer, cws);
            }
        }
        
        // Deactivate offer and listing if exists
        offer.active = false;
        if (cws.territoryListings[offer.territoryId].active) {
            cws.territoryListings[offer.territoryId].active = false;
        }
        
        // Cancel all other offers for this territory
        _cancelAllOffersForTerritory(offer.territoryId, cws, hs);
        
        emit TerritoryOfferAccepted(offerId, offer.territoryId, seller, buyer, totalPrice);
        emit TerritorySold(offer.territoryId, seller, buyer, totalPrice);
    }

    // ============================================================================
    // VIEW FUNCTIONS
    // ============================================================================

    /**
     * @notice Get territory listing details
     * @param territoryId Territory to check
     * @return listing Full listing details
     */
    function getTerritoryListing(uint256 territoryId) 
        external 
        view 
        returns (LibColonyWarsStorage.TerritoryListing memory) 
    {
        return LibColonyWarsStorage.colonyWarsStorage().territoryListings[territoryId];
    }

    /**
     * @notice Get all active listings in marketplace
     * @return territoryIds Array of listed territory IDs
     * @return sellers Array of seller colonies
     * @return prices Array of asking prices
     * @return expiryTimes Array of expiry timestamps
     */
    function getAllTerritoryListings() 
        external 
        view 
        returns (
            uint256[] memory territoryIds,
            bytes32[] memory sellers,
            uint256[] memory prices,
            uint32[] memory expiryTimes
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        uint256 activeCount = 0;
        for (uint256 i = 1; i <= cws.territoryCounter; i++) {
            LibColonyWarsStorage.TerritoryListing storage listing = cws.territoryListings[i];
            if (listing.active && (listing.expiryTime == 0 || block.timestamp <= listing.expiryTime)) {
                activeCount++;
            }
        }
        
        territoryIds = new uint256[](activeCount);
        sellers = new bytes32[](activeCount);
        prices = new uint256[](activeCount);
        expiryTimes = new uint32[](activeCount);
        
        uint256 index = 0;
        for (uint256 i = 1; i <= cws.territoryCounter; i++) {
            LibColonyWarsStorage.TerritoryListing storage listing = cws.territoryListings[i];
            if (listing.active && (listing.expiryTime == 0 || block.timestamp <= listing.expiryTime)) {
                territoryIds[index] = i;
                sellers[index] = listing.seller;
                prices[index] = listing.askPrice;
                expiryTimes[index] = listing.expiryTime;
                index++;
            }
        }
    }

    /**
     * @notice Get all active offers for a territory
     * @param territoryId Territory to check offers for
     * @return offerIds Array of offer IDs
     * @return buyers Array of buyer colonies
     * @return prices Array of offer prices
     * @return expiryTimes Array of offer expiry timestamps
     */
    function getTerritoryOffers(uint256 territoryId) 
        external 
        view 
        returns (
            bytes32[] memory offerIds,
            bytes32[] memory buyers,
            uint256[] memory prices,
            uint32[] memory expiryTimes
        ) 
    {
        LibColonyWarsStorage.ColonyWarsStorage storage cws = LibColonyWarsStorage.colonyWarsStorage();
        
        bytes32[] storage allOfferIds = cws.territoryOfferIds[territoryId];
        uint256 activeCount = 0;
        
        for (uint256 i = 0; i < allOfferIds.length; i++) {
            LibColonyWarsStorage.TerritoryOffer storage offer = cws.territoryOffers[allOfferIds[i]];
            if (offer.active && block.timestamp <= offer.expiryTime) {
                activeCount++;
            }
        }
        
        offerIds = new bytes32[](activeCount);
        buyers = new bytes32[](activeCount);
        prices = new uint256[](activeCount);
        expiryTimes = new uint32[](activeCount);
        
        uint256 index = 0;
        for (uint256 i = 0; i < allOfferIds.length; i++) {
            LibColonyWarsStorage.TerritoryOffer storage offer = cws.territoryOffers[allOfferIds[i]];
            if (offer.active && block.timestamp <= offer.expiryTime) {
                offerIds[index] = allOfferIds[i];
                buyers[index] = offer.buyer;
                prices[index] = offer.offerPrice;
                expiryTimes[index] = offer.expiryTime;
                index++;
            }
        }
    }

    /**
     * @notice Get specific offer details
     * @param offerId Offer ID to query
     * @return offer Full offer details
     */
    function getTerritoryOfferDetails(bytes32 offerId) 
        external 
        view 
        returns (LibColonyWarsStorage.TerritoryOffer memory) 
    {
        return LibColonyWarsStorage.colonyWarsStorage().territoryOffers[offerId];
    }

    // ============================================================================
    // INTERNAL HELPERS
    // ============================================================================

    /**
     * @notice Count active territories controlled by a colony
     */
    function _countActiveColonyTerritories(
        bytes32 colonyId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal view returns (uint256 count) {
        uint256[] storage territoryIds = cws.colonyTerritories[colonyId];
        count = 0;
        
        for (uint256 i = 0; i < territoryIds.length; i++) {
            LibColonyWarsStorage.Territory storage territory = cws.territories[territoryIds[i]];
            if (territory.active && territory.controllingColony == colonyId) {
                count++;
            }
        }
        
        return count;
    }

    /**
     * @notice Remove territory from colony's territory list
     */
    function _removeTerritoryFromColony(
        uint256 territoryId,
        bytes32 colonyId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        uint256[] storage territoryIds = cws.colonyTerritories[colonyId];
        
        for (uint256 i = 0; i < territoryIds.length; i++) {
            if (territoryIds[i] == territoryId) {
                territoryIds[i] = territoryIds[territoryIds.length - 1];
                territoryIds.pop();
                break;
            }
        }
    }

    /**
     * @notice Cancel all offers for a territory
     */
    function _cancelAllOffersForTerritory(
        uint256 territoryId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws,
        LibHenomorphsStorage.HenomorphsStorage storage hs
    ) internal {
        bytes32[] storage offerIds = cws.territoryOfferIds[territoryId];
        
        for (uint256 i = 0; i < offerIds.length; i++) {
            LibColonyWarsStorage.TerritoryOffer storage offer = cws.territoryOffers[offerIds[i]];
            
            if (offer.active) {
                address buyerAddress = hs.colonyCreators[offer.buyer];
                if (buyerAddress != address(0)) {
                    // Refund from treasury
                    LibFeeCollection.transferFromTreasury(
                        buyerAddress,
                        offer.offerPrice,
                        "territory_offer_auto_refund"
                    );
                }
                
                offer.active = false;
                emit TerritoryOfferCancelled(offerIds[i], offer.buyer, offer.offerPrice);
            }
        }
        
        delete cws.territoryOfferIds[territoryId];
    }

    /**
     * @notice Remove specific offer from territory's offer list
     */
    function _removeOfferFromList(
        uint256 territoryId,
        bytes32 offerId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        bytes32[] storage offerIds = cws.territoryOfferIds[territoryId];
        
        for (uint256 i = 0; i < offerIds.length; i++) {
            if (offerIds[i] == offerId) {
                offerIds[i] = offerIds[offerIds.length - 1];
                offerIds.pop();
                break;
            }
        }
    }

    /**
     * @notice Activate Territory Card (assign to colony)
     */
    function _activateTerritoryCard(
        uint256,
        uint256 cardTokenId,
        bytes32 colonyId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        if (cws.contractAddresses.territoryCards == address(0)) {
            return;
        }
        
        uint256 colonyIdUint = uint256(colonyId);
        ITerritoryCards(cws.contractAddresses.territoryCards).assignToColony(cardTokenId, colonyIdUint);
    }

    /**
     * @notice Deactivate Territory Card
     */
    function _deactivateTerritoryCard(
        uint256,
        uint256 cardTokenId,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        if (cws.contractAddresses.territoryCards == address(0)) {
            return;
        }
        
        ITerritoryCards(cws.contractAddresses.territoryCards).deactivateTerritory(cardTokenId);
    }

    /**
     * @notice Transfer Territory Card NFT between addresses
     * @dev Uses IERC721 transferFrom for standard NFT transfer
     * @param cardTokenId Card token ID to transfer
     * @param from Current owner address
     * @param to New owner address
     * @param cws Storage reference
     */
    function _transferTerritoryCard(
        uint256 cardTokenId,
        address from,
        address to,
        LibColonyWarsStorage.ColonyWarsStorage storage cws
    ) internal {
        if (cws.contractAddresses.territoryCards == address(0)) {
            return;
        }
        
        // Use IERC721 transferFrom for NFT transfer
        IERC721(cws.contractAddresses.territoryCards).transferFrom(from, to, cardTokenId);
    }
}

/**
 * @title ITerritoryCards
 * @notice Interface for Territory Cards collection
 */
interface ITerritoryCards {
    function assignToColony(uint256 tokenId, uint256 colonyId) external;
    function deactivateTerritory(uint256 tokenId) external;
}

