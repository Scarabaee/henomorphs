// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {StakedSpecimen} from "../../libraries/StakingModel.sol";
import {LibStakingStorage} from "../../diamonds/staking/libraries/LibStakingStorage.sol";

/**
 * @title IStakingIntegration
 * @notice Interface for integrating with Henomorphs Staking Diamond
 * @dev Read-only interface for verification purposes
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
interface IStakingIntegration {
    
    /**
     * @notice Get all staked tokens for a user
     * @param staker User address
     * @return tokenIds Array of combined token IDs (collection + token)
     */
    function getStakerTokens(address staker) 
        external 
        view 
        returns (uint256[] memory tokenIds);
    
    /**
     * @notice Get staked specimen details
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return specimen Staked specimen data
     */
    function getStakedSpecimen(uint256 collectionId, uint256 tokenId) 
        external 
        view 
        returns (StakedSpecimen memory specimen);
    
    /**
     * @notice Get colony ID for a staked token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return colonyId Colony ID (bytes32(0) if not in colony)
     */
    function getTokenColony(uint256 collectionId, uint256 tokenId) 
        external 
        view 
        returns (bytes32 colonyId);
    
    /**
     * @notice Get loyalty tier for an address
     * @param user User address
     * @return tierLevel Loyalty tier level (0-5)
     */
    function getLoyaltyTierForAddress(address user) 
        external 
        view 
        returns (LibStakingStorage.LoyaltyTierLevel tierLevel);
    
    /**
     * @notice Check if user is colony creator
     * @param colonyId Colony ID
     * @param user User address
     * @return isCreator Whether user is colony creator
     */
    function isColonyCreator(bytes32 colonyId, address user) 
        external 
        view 
        returns (bool isCreator);
    
    /**
     * @notice Get total number of staked tokens for a user
     * @param staker User address
     * @return count Number of staked tokens
     */
    function getStakerTokenCount(address staker) 
        external 
        view 
        returns (uint256 count);
    
    /**
     * @notice Check if a token is currently staked
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return staked Whether token is staked
     */
    function isTokenStaked(uint256 collectionId, uint256 tokenId) 
        external 
        view 
        returns (bool staked);
    
    /**
     * @notice Get staking duration for a token
     * @param collectionId Collection ID
     * @param tokenId Token ID
     * @return duration Duration in seconds
     */
    function getStakingDuration(uint256 collectionId, uint256 tokenId) 
        external 
        view 
        returns (uint256 duration);
    
    /**
     * @notice Check if user has active loyalty bonus
     * @param user User address
     * @return hasBonus Whether user has active loyalty bonus
     */
    function hasActiveLoyaltyBonus(address user) 
        external 
        view 
        returns (bool hasBonus);
    
    /**
     * @notice Get variant distribution for user's staked tokens
     * @param staker User address
     * @return distribution Array with count of each variant [0, v1_count, v2_count, v3_count, v4_count]
     */
    function getVariantDistribution(address staker) 
        external 
        view 
        returns (uint8[5] memory distribution);
    
    /**
     * @notice Get count of tokens with minimum infusion level
     * @param staker User address
     * @param minInfusionLevel Minimum infusion level
     * @return count Number of tokens meeting criteria
     */
    function getInfusedTokenCount(address staker, uint8 minInfusionLevel) 
        external 
        view 
        returns (uint256 count);
    
    /**
     * @notice Calculate average staking duration for user's tokens
     * @param staker User address
     * @return averageDays Average staking duration in days
     */
    function getAverageStakingDays(address staker) 
        external 
        view 
        returns (uint256 averageDays);
    
    /**
     * @notice Calculate average level for user's staked tokens
     * @param staker User address
     * @return averageLevel Average token level
     */
    function getAverageLevel(address staker) 
        external 
        view 
        returns (uint256 averageLevel);
}
