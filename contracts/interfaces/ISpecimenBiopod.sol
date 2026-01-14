// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "../libraries/HenomorphsModel.sol";

/**
 * @dev Interface for Biopod contracts
 */
interface ISpecimenBiopod {

    /**
     * @dev Zwraca dane kalibracji bez modyfikowania stanu
     * @param collectionId Token collection ID
     * @param tokenId Token ID
     * @return Calibration struktura z aktualnymi danymi kalibracji
     */
    function probeCalibration(uint256 collectionId, uint256 tokenId) external view returns (Calibration memory);
    
    /**
     * @dev Updates charge data for a token
     * @param collectionId Token collection ID
     * @param tokenId Token ID
     * @param charge New charge level
     * @param timestamp Update timestamp
     * @return Success of operation
     */
    function updateChargeData(uint256 collectionId, uint256 tokenId, uint256 charge, uint256 timestamp) external returns (bool);
    
    /**
     * @dev Updates calibration status for a token
     * @param collectionId Token collection ID
     * @param tokenId Token ID
     * @param level New calibration level
     * @param wear New wear level
     * @return Success of operation
     */
    function updateCalibrationStatus(uint256 collectionId, uint256 tokenId, uint256 level, uint256 wear) external returns (bool);
    
    /**
     * @dev Sets processor approval
     * @param processor Processor address
     * @param approved Approval status
     */
    function setProcessorApproval(address processor, bool approved) external;
    
    /**
     * @dev Checks if processor is approved
     * @param processor Processor address 
     * @return Whether processor is approved
     */
    function isProcessorApproved(address processor) external view returns (bool);
    
    /**
     * @dev Applies fatigue to a token
     * @param collectionId Token collection ID
     * @param tokenId Token ID
     * @param amount Amount of fatigue to add
     * @return Success of operation
     */
    function applyFatigue(uint256 collectionId, uint256 tokenId, uint256 amount) external returns (bool);
    
    /**
     * @dev Adds experience to a token
     * @param collectionId Token collection ID
     * @param tokenId Token ID
     * @param amount Amount of experience to add
     * @return Success of operation
     */
    function applyExperienceGain(uint256 collectionId, uint256 tokenId, uint256 amount) external returns (bool);
    
    /**
     * @dev Updates wear data for a token
     * @param collectionId Token collection ID
     * @param tokenId Token ID
     * @param wear New wear value
     * @return Success of operation
     */
    function updateWearData(uint256 collectionId, uint256 tokenId, uint256 wear) external returns (bool);
    
    /**
     * @dev Repairs token wear
     * @param collectionId Token collection ID
     * @param tokenId Token ID
     * @param repairAmount Amount of wear to repair
     * @return Success of operation
     */
    function applyWearRepair(uint256 collectionId, uint256 tokenId, uint256 repairAmount) external returns (bool);
}