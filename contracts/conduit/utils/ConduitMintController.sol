// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title ConduitMintController
/// @notice Manages phased minting with whitelist verification and progressive pricing
contract ConduitMintController is 
    Initializable,
    OwnableUpgradeable, 
    UUPSUpgradeable 
{
    
    struct MintPhase {
        bytes32 merkleRoot;
        uint256 startTime;
        uint256 endTime;
        uint256 maxPerAddress;
        uint256 basePrice;
        bool isActive;
        string phaseName;
        bool allowZicoPayment;
        uint256 maxTotalSupply;
        uint256 totalMinted;
    }

    struct PublicMintConfig {
        uint256 maxPerAddress;
        uint256 basePrice;
        bool isActive;
        uint256 startTime;
        uint256 maxTotalSupply;
        uint256 totalMinted;
    }

    // Current active mint phase
    uint256 public currentPhase;
    
    // Mapping of phase ID to phase configuration
    mapping(uint256 => MintPhase) public mintPhases;
    
    // Public mint configuration
    PublicMintConfig public publicMintConfig;
    
    // Tracking mints per address per phase
    mapping(uint256 => mapping(address => uint256)) public mintedPerPhase;
    
    // Tracking total public mints per address
    mapping(address => uint256) public publicMintCount;

    // Basic whitelist mapping per phase (address => allowed)
    mapping(uint256 => mapping(address => bool)) public whitelisted;

    // Progressive pricing multipliers (dynamic array)
    uint256[] public priceMultipliers;

    uint256 public zicoPerCore;
    
    // Events
    event MintPhaseCreated(
        uint256 indexed phaseId,
        bytes32 merkleRoot,
        uint256 startTime,
        uint256 endTime,
        uint256 maxPerAddress,
        uint256 basePrice,
        uint256 maxTotalSupply
    );
    
    event PhaseActivated(uint256 indexed phaseId);
    event PhaseDeactivated(uint256 indexed phaseId);
    event PublicMintConfigured(uint256 maxPerAddress, uint256 basePrice, uint256 startTime, uint256 maxTotalSupply);
    event PriceMultipliersUpdated(uint256[] newMultipliers);
    event WhitelistUpdated(uint256 indexed phaseId, address[] addresses, bool[] allowed);
    
    // Custom errors
    error InvalidPhase();
    error PhaseNotActive();
    error PhaseNotStarted();
    error PhaseEnded();
    error InvalidProof();
    error MintLimitExceeded();
    error PublicMintNotActive();
    error InvalidConfiguration();
    error SupplyExceeded();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the mint controller
    /// @param _owner Contract owner
    function initialize(address _owner) public initializer {
        if (_owner == address(0)) revert InvalidConfiguration();
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        
        currentPhase = 0;
        
        // Initialize default progressive pricing
        priceMultipliers = [
            10000, 9980, 9930, 9850, 9740, 
            9590, 9400, 9190, 8940, 8660, 
            8350, 8000
        ];
    }

    /// @notice Create a new mint phase 
    function createMintPhase(
        uint256 phaseId,
        bytes32 merkleRoot,
        uint256 startTime,
        uint256 endTime,
        uint256 maxPerAddress,
        uint256 basePrice,
        string calldata phaseName,
        bool allowZicoPayment,
        uint256 maxTotalSupply
    ) external onlyOwner {
        if (startTime >= endTime) revert InvalidConfiguration();
        if (maxPerAddress == 0) revert InvalidConfiguration();
        if (maxTotalSupply == 0) revert InvalidConfiguration();
        
        mintPhases[phaseId] = MintPhase({
            merkleRoot: merkleRoot,
            startTime: startTime,
            endTime: endTime,
            maxPerAddress: maxPerAddress,
            basePrice: basePrice,
            isActive: false,
            phaseName: phaseName,
            allowZicoPayment: allowZicoPayment,
            maxTotalSupply: maxTotalSupply,
            totalMinted: 0
        });
        
        emit MintPhaseCreated(phaseId, merkleRoot, startTime, endTime, maxPerAddress, basePrice, maxTotalSupply);
    }

    /// @notice Activate a mint phase
    function activatePhase(uint256 phaseId) external onlyOwner {
        if (mintPhases[phaseId].startTime == 0) revert InvalidPhase();
        
        mintPhases[phaseId].isActive = true;
        currentPhase = phaseId;
        
        emit PhaseActivated(phaseId);
    }

    /// @notice Deactivate current phase
    function deactivatePhase(uint256 phaseId) external onlyOwner {
        mintPhases[phaseId].isActive = false;
        emit PhaseDeactivated(phaseId);
    }

    /// @notice Configure public mint parameters
    function configurePublicMint(
        uint256 maxPerAddress,
        uint256 basePrice,
        uint256 startTime,
        uint256 maxTotalSupply
    ) external onlyOwner {
        if (maxPerAddress == 0) revert InvalidConfiguration();
        if (maxTotalSupply == 0) revert InvalidConfiguration();
        
        publicMintConfig = PublicMintConfig({
            maxPerAddress: maxPerAddress,
            basePrice: basePrice,
            isActive: true,
            startTime: startTime,
            maxTotalSupply: maxTotalSupply,
            totalMinted: 0
        });
        
        emit PublicMintConfigured(maxPerAddress, basePrice, startTime, maxTotalSupply);
    }

    /// @notice Update whitelist for a specific phase
    function updateWhitelist(
        uint256 phaseId,
        address[] calldata addresses,
        bool[] calldata allowed
    ) external onlyOwner {
        if (addresses.length != allowed.length) revert InvalidConfiguration();
        if (mintPhases[phaseId].startTime == 0) revert InvalidPhase();
        
        for (uint256 i = 0; i < addresses.length; i++) {
            whitelisted[phaseId][addresses[i]] = allowed[i];
        }
        
        emit WhitelistUpdated(phaseId, addresses, allowed);
    }

    /// @notice Verify mint eligibility and calculate progressive price
    function verifyMint(
        address to,
        uint256 quantity,
        uint8 coreCount,
        bytes32[] calldata merkleProof,
        bool useZico,
        bool isPublic
    ) external returns (uint256 totalPrice, bool allowZico) {
        if (isPublic) {
            return _verifyPublicMint(to, quantity, coreCount);
        } else {
            return _verifyWhitelistMint(to, quantity, coreCount, merkleProof, useZico);
        }
    }
    
    /// @notice Calculate progressive price for quantity
    function calculatePrice(uint256 pricePerCore, uint8 coreCount, uint256 quantity) 
        public view returns (uint256 totalPrice) 
    {
        if (quantity == 0 || coreCount == 0) revert InvalidConfiguration();
        
        totalPrice = 0;
        uint256 coreIndex = 0;
        
        // Dla każdego tokenu
        for (uint256 t = 0; t < quantity; t++) {
            // Dla każdego core w tym tokenie
            for (uint256 c = 0; c < coreCount; c++) {
                if (coreIndex < priceMultipliers.length) {
                    totalPrice += (pricePerCore * priceMultipliers[coreIndex]) / 10000;
                } else {
                    totalPrice += (pricePerCore * priceMultipliers[priceMultipliers.length - 1]) / 10000;
                }
                coreIndex++;
            }
        }
    }

    function setZicoPerCore(uint256 price) external onlyOwner {
        zicoPerCore = price;
    }

    // Reset mint count dla konkretnego portfela w konkretnej fazie
    function resetWalletMints(uint256 phaseId, address wallet, uint256 newCount) external onlyOwner {
        mintedPerPhase[phaseId][wallet] = newCount;
    }

    // Reset public mint count dla portfela
    function resetPublicMints(address wallet, uint256 newCount) external onlyOwner {
        publicMintCount[wallet] = newCount;
    }

    // Batch reset dla wielu portfeli jednocześnie
    function batchResetMints(
        uint256 phaseId, 
        address[] calldata wallets, 
        uint256[] calldata newCounts
    ) external onlyOwner {
        if (wallets.length != newCounts.length) revert InvalidConfiguration();
        
        for (uint256 i = 0; i < wallets.length; i++) {
            mintedPerPhase[phaseId][wallets[i]] = newCounts[i];
        }
    }

    /// @notice Get current phase information
    function getCurrentPhase() external view returns (MintPhase memory phase) {
        return mintPhases[currentPhase];
    }

    /// @notice Get public mint configuration
    function getPublicConfig() external view returns (PublicMintConfig memory config) {
        return publicMintConfig;
    }

    /// @notice Check if address is whitelisted for current phase
    function isWhitelisted(
        address account,
        bytes32[] calldata merkleProof
    ) external view returns (bool isWhitelisted) {
        MintPhase memory phase = mintPhases[currentPhase];
        
        // First check basic whitelist
        if (!whitelisted[currentPhase][account]) return false;
        
        // If merkle root is set, also verify merkle proof
        if (phase.merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(account));
            return MerkleProof.verify(merkleProof, phase.merkleRoot, leaf);
        }
        
        return true;
    }

    /// @notice Get remaining mint allocation for address in current phase
    function remainingWhitelist(address account) external view returns (uint256 remaining) {
        uint256 phaseId = currentPhase;
        MintPhase memory phase = mintPhases[phaseId];
        uint256 minted = mintedPerPhase[phaseId][account];
        
        return phase.maxPerAddress > minted ? phase.maxPerAddress - minted : 0;
    }

    /// @notice Get remaining public mint allocation for address
    function remainingPublic(address account) external view returns (uint256 remaining) {
        uint256 minted = publicMintCount[account];
        return publicMintConfig.maxPerAddress > minted ? 
               publicMintConfig.maxPerAddress - minted : 0;
    }

    /// @notice Check if public mint is currently available
    function isPublicActive() external view returns (bool available) {
        return publicMintConfig.isActive && 
               block.timestamp >= publicMintConfig.startTime &&
               publicMintConfig.totalMinted < publicMintConfig.maxTotalSupply;
    }

    /// @notice Update progressive pricing multipliers
    function updatePriceMultipliers(uint256[] calldata newMultipliers) external onlyOwner {
        if (newMultipliers.length == 0) revert InvalidConfiguration();
        
        delete priceMultipliers;
        
        for (uint256 i = 0; i < newMultipliers.length; i++) {
            if (newMultipliers[i] > 10000) revert InvalidConfiguration();
            priceMultipliers.push(newMultipliers[i]);
        }
        
        emit PriceMultipliersUpdated(newMultipliers);
    }

    /// @notice Emergency function to disable public mint
    function disablePublicMint() external onlyOwner {
        publicMintConfig.isActive = false;
    }

    /// @notice Update merkle root for existing phase
    function updateMerkleRoot(uint256 phaseId, bytes32 newMerkleRoot) external onlyOwner {
        if (mintPhases[phaseId].startTime == 0) revert InvalidPhase();
        mintPhases[phaseId].merkleRoot = newMerkleRoot;
    }

    /// @notice Check if address is on basic whitelist for specific phase
    function isBasicWhitelisted(uint256 phaseId, address account) external view returns (bool allowed) {
        return whitelisted[phaseId][account];
    }

    /// @notice Internal function to verify whitelist mint
    function _verifyWhitelistMint(
        address to,
        uint256 quantity,
        uint8 coreCount,
        bytes32[] calldata merkleProof,
        bool useZico
    ) internal returns (uint256 totalPrice, bool allowZico) {
        uint256 phaseId = currentPhase;
        MintPhase storage phase = mintPhases[phaseId];
        
        // Standardowe sprawdzenia
        if (!phase.isActive) revert PhaseNotActive();
        if (block.timestamp < phase.startTime) revert PhaseNotStarted();
        if (block.timestamp > phase.endTime) revert PhaseEnded();
        if (phase.totalMinted + quantity > phase.maxTotalSupply) revert SupplyExceeded();
        
        if (!whitelisted[phaseId][to]) revert InvalidProof();
        
        if (phase.merkleRoot != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(to));
            if (!MerkleProof.verify(merkleProof, phase.merkleRoot, leaf)) {
                revert InvalidProof();
            }
        }
        
        if (useZico && !phase.allowZicoPayment) {
            revert InvalidConfiguration();
        }
        
        uint256 currentMinted = mintedPerPhase[phaseId][to];
        if (currentMinted + quantity > phase.maxPerAddress) {
            revert MintLimitExceeded();
        }
        
        mintedPerPhase[phaseId][to] = currentMinted + quantity;
        phase.totalMinted += quantity;
        
        // Pricing z progresją per core dla obu walut
        if (useZico) {
            if (zicoPerCore == 0) revert InvalidConfiguration();
            totalPrice = calculatePrice(zicoPerCore, coreCount, quantity);
        } else {
            totalPrice = calculatePrice(phase.basePrice, coreCount, quantity);
        }
        
        allowZico = phase.allowZicoPayment;
    }

    /// @notice Internal function to verify public mint
    function _verifyPublicMint(
        address to,
        uint256 quantity,
        uint8 coreCount
    ) internal returns (uint256 totalPrice, bool allowZico) {
        PublicMintConfig storage config = publicMintConfig;
        
        if (!config.isActive) revert PublicMintNotActive();
        if (block.timestamp < config.startTime) revert PhaseNotStarted();
        if (config.totalMinted + quantity > config.maxTotalSupply) revert SupplyExceeded();
        
        uint256 currentMinted = publicMintCount[to];
        if (currentMinted + quantity > config.maxPerAddress) {
            revert MintLimitExceeded();
        }
        
        publicMintCount[to] = currentMinted + quantity;
        config.totalMinted += quantity;
        
        // POL z progresją per core
        totalPrice = calculatePrice(config.basePrice, coreCount, quantity);
        allowZico = false;
    }

    /// @notice Authorize upgrade (UUPS pattern)
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Get implementation version
    function getVersion() external pure returns (string memory version) {
        return "2.0.0";
    }
}