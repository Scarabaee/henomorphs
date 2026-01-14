// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IConduit.sol";
import "../interfaces/IConduitRedemptionHandler.sol";
import "../interfaces/IConduitTokenDescriptor.sol";
import "../interfaces/IConduitMintController.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
 
/// @title HenomorphsConduit
/// @notice NFT collection serving as conduits to the Henomorphs ecosystem
/// @dev Upgradeable ERC721 with configurable max cores system and on-chain metadata
contract HenomorphsConduit is 
    Initializable,
    ERC721Upgradeable, 
    OwnableUpgradeable, 
    PausableUpgradeable,
    UUPSUpgradeable,
    IConduit 
{
    using SafeERC20 for IERC20;

    /// @notice Payable token contract address (configurable alternative payment)
    address public payableToken;
    
    /// @notice Maximum cores per individual token (constant)
    uint8 public constant MAX_CORES_PER_TOKEN = 12;

    /// @notice Next token ID to be minted
    uint256 public nextTokenId;
    
    /// @notice Default expiry duration for new tokens
    uint256 public defaultExpiryDuration;
    
    /// @notice Treasury address for collecting payments
    address public treasury;
    
    /// @notice Contract handling core redemptions
    address public redemptionHandler;
    
    /// @notice Contract generating token metadata and SVG
    address public tokenDescriptor;

    /// @notice Configurable mint controller contract
    address public mintController;

    /// @notice Maximum total cores per wallet across all tokens (configurable)
    uint256 public maxCoresPerWallet;

    /// @notice Token configurations mapping
    mapping(uint256 => TokenConfig) public tokenConfigs;
    
    /// @notice Core pricing by count (native token and payable token)
    mapping(uint8 => CorePricing) public corePricing;
    
    /// @notice Cores per wallet tracking (total across all tokens)
    mapping(address => uint256) public walletCoreCount;
    
    /// @notice Public mint tracking per wallet
    mapping(address => uint256) public publicMintCount;
    
    /// @notice Total number of active (non-burned) tokens
    uint256 public totalActiveSupply;

    /// @notice Whether whitelist mode is enabled (preserved for upgrade compatibility)
    bool public whitelistModeEnabled;

    /// @notice Maximum total supply limit
    uint256 public maxTotalSupply;

    /// @notice Current total minted count
    uint256 public totalMinted;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param _name Token collection name
    /// @param _symbol Token collection symbol  
    /// @param _owner Contract owner
    /// @param _treasury Treasury address
    /// @param _defaultExpiryDuration Default expiry duration in seconds
    /// @param _maxCoresPerWallet Maximum cores per wallet
    /// @param _payableToken Address of alternative payment token (address(0) to disable)
    /// @param _maxTotalSupply Maximum total supply limit
    function initialize(
        string memory _name,
        string memory _symbol,
        address _owner,
        address _treasury,
        uint256 _defaultExpiryDuration,
        uint256 _maxCoresPerWallet,
        address _payableToken,
        uint256 _maxTotalSupply
    ) public initializer {
        if (_owner == address(0) || _treasury == address(0)) revert ZeroAddress();
        if (_maxTotalSupply == 0) revert InvalidConfiguration();
        
        __ERC721_init(_name, _symbol);
        __Ownable_init(_owner);
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        nextTokenId = 1;
        treasury = _treasury;
        defaultExpiryDuration = _defaultExpiryDuration;
        totalActiveSupply = 0;
        totalMinted = 0;
        maxCoresPerWallet = _maxCoresPerWallet;
        payableToken = _payableToken;
        maxTotalSupply = _maxTotalSupply;
        whitelistModeEnabled = true; // Keep for compatibility
        
        // Initialize default core pricing (not used with progressive pricing)
        _setCorePrice(1, 0.1 ether, 1000 * 10**18);
        _setCorePrice(5, 0.4 ether, 3600 * 10**18);
        _setCorePrice(12, 0.8 ether, 7000 * 10**18);
    }

    /// @notice Mint with whitelist verification using progressive pricing
    /// @param coreCount Number of cores to assign to the token
    /// @param quantity Number of tokens to mint
    /// @param merkleProof Merkle proof for whitelist verification
    /// @param useToken Whether to pay with alternative token (if allowed by phase)
    function whitelistMint(
        uint8 coreCount,
        uint256 quantity,
        bytes32[] calldata merkleProof,
        bool useToken
    ) external payable whenNotPaused {
        // Sprawdzenia (bez zmian)
        if (coreCount == 0 || coreCount > MAX_CORES_PER_TOKEN) revert InvalidCoreCount();
        if (quantity == 0) revert InvalidConfiguration();
        if (totalMinted + quantity > maxTotalSupply) revert SupplyExceeded();
        
        uint256 totalCoresNeeded = uint256(coreCount) * quantity;
        if (walletCoreCount[msg.sender] + totalCoresNeeded > maxCoresPerWallet) {
            revert MintLimitExceeded();
        }
        
        // Dodaj coreCount do wywołania
        uint256 totalPrice;
        bool tokenAllowed;
        if (mintController != address(0)) {
            (totalPrice, tokenAllowed) = IConduitMintController(mintController).verifyMint(
                msg.sender,
                quantity,
                coreCount,    // DODANE
                merkleProof,
                useToken,
                false
            );
        } else {
            revert InvalidConfiguration();
        }
        
        // Płatność (bez zmian)
        if (useToken) {
            if (!tokenAllowed) revert InvalidConfiguration();
            if (payableToken == address(0)) revert InvalidConfiguration();
            IERC20(payableToken).safeTransferFrom(msg.sender, treasury, totalPrice);
        } else {
            if (msg.value < totalPrice) revert InsufficientPayment();
            _transferNative(treasury, totalPrice);
        }
        
        // Mint (bez zmian)
        for (uint256 i = 0; i < quantity; i++) {
            _mintSingle(msg.sender, coreCount);
        }
    }

    /// @notice Public mint with progressive pricing
    /// @param coreCount Number of cores to assign to the token
    /// @param quantity Number of tokens to mint
    /// @param useToken Whether to pay with alternative token
    function publicMint(
        uint8 coreCount,
        uint256 quantity,
        bool useToken
    ) external payable whenNotPaused {
        // Sprawdzenia (bez zmian)
        if (coreCount == 0 || coreCount > MAX_CORES_PER_TOKEN) revert InvalidCoreCount();
        if (quantity == 0) revert InvalidConfiguration();
        if (totalMinted + quantity > maxTotalSupply) revert SupplyExceeded();
        
        uint256 totalCoresNeeded = uint256(coreCount) * quantity;
        if (walletCoreCount[msg.sender] + totalCoresNeeded > maxCoresPerWallet) {
            revert MintLimitExceeded();
        }
        
        // Dodaj coreCount do wywołania
        uint256 totalPrice;
        bool tokenAllowed;
        if (mintController != address(0)) {
            (totalPrice, tokenAllowed) = IConduitMintController(mintController).verifyMint(
                msg.sender,
                quantity,
                coreCount,    // DODANE
                new bytes32[](0),
                useToken,
                true
            );
        } else {
            revert InvalidConfiguration();
        }
        
        // Public nie akceptuje ZICO
        if (useToken) revert InvalidConfiguration();
        if (msg.value < totalPrice) revert InsufficientPayment();
        _transferNative(treasury, totalPrice);
        
        // Mint (bez zmian)
        for (uint256 i = 0; i < quantity; i++) {
            _mintSingle(msg.sender, coreCount);
        }
    }

    /// @notice Admin mint function
    /// @param to Address to mint to
    /// @param coreCount Number of cores to assign
    /// @param quantity Number of tokens to mint
    function adminMint(
        address to,
        uint8 coreCount,
        uint256 quantity
    ) external onlyOwner {
        if (coreCount == 0 || coreCount > MAX_CORES_PER_TOKEN) revert InvalidCoreCount();
        if (quantity == 0 || to == address(0)) revert InvalidConfiguration();
        if (totalMinted + quantity > maxTotalSupply) revert SupplyExceeded();
        
        for (uint256 i = 0; i < quantity; i++) {
            _mintSingle(to, coreCount);
        }
    }

    /// @notice Redeem cores from a token
    /// @param tokenId Token to redeem cores from
    /// @param coresCount Number of cores to redeem
    /// @param data Additional data to pass to redemption handler
    function redeemCores(uint256 tokenId, uint8 coresCount, bytes calldata data) 
        external 
        whenNotPaused 
    {
        if (!_isAuthorizedForToken(msg.sender, tokenId)) revert Unauthorized();
        if (redemptionHandler == address(0)) revert ZeroAddress();
        
        TokenConfig storage config = tokenConfigs[tokenId];
        if (!config.isActive) revert TokenNotActive();
        if (block.timestamp > config.expiryDate) revert TokenExpired();
        if (config.coreCount < coresCount) revert InsufficientCores();

        // Call external redemption handler
        bool success = IConduitRedemptionHandler(redemptionHandler).onCoreRedemption(
            tokenId,
            coresCount,
            msg.sender,
            data
        );
        
        if (!success) revert RedemptionFailed();

        // Update core counts
        config.coreCount -= coresCount;
        walletCoreCount[_ownerOf(tokenId)] -= coresCount;
        uint8 remainingCores = config.coreCount;
        
        emit CoresRedeemed(tokenId, msg.sender, coresCount, remainingCores);

        // Burn token if no cores left
        if (remainingCores == 0) {
            config.isActive = false;
            totalActiveSupply--;
            _burn(tokenId);
            emit TokenBurned(tokenId);
        }
    }

    /// @notice Generate on-chain token URI with metadata and SVG
    /// @param tokenId The token ID
    /// @return Token URI with complete metadata
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_exists(tokenId)) revert TokenNotActive();
        if (tokenDescriptor == address(0)) {
            return _generateBasicTokenURI(tokenId);
        }
        
        TokenConfig memory config = tokenConfigs[tokenId];
        IConduitTokenDescriptor.TokenMetadata memory metadata = IConduitTokenDescriptor.TokenMetadata({
            tokenId: tokenId,
            coreCount: config.coreCount,
            expiryDate: config.expiryDate,
            isActive: config.isActive,
            owner: _ownerOf(tokenId)
        });
        
        return IConduitTokenDescriptor(tokenDescriptor).tokenURI(metadata);
    }

    function contractURI() external view returns (string memory) {
        if (tokenDescriptor == address(0)) {
            return string(abi.encodePacked(
                'data:application/json;utf8,{"name":"',
                name(),
                '","description":"Entry to the Henomorphs Ecosystem. Conduit tokens provide access to redeem other tokens based on core count.","image":"https://henomorphs.zico.network/images/collection.png","external_link":"https://henomorphs.zico.network","seller_fee_basis_points":500,"fee_recipient":"0x',
                _addressToString(treasury),
                '","category":"pfps"}'
            ));
        }
        
        return IConduitTokenDescriptor(tokenDescriptor).contractURI();
    }

    /// @notice Get remaining core allocation for a wallet
    /// @param wallet Wallet address to check
    /// @return remaining Remaining cores that can be minted
    function getRemainingCoreAllocation(address wallet) external view returns (uint256 remaining) {
        return maxCoresPerWallet > walletCoreCount[wallet] ? 
               maxCoresPerWallet - walletCoreCount[wallet] : 0;
    }

    /// @notice Check if wallet can mint specific quantity and core count
    /// @param wallet Wallet to check
    /// @param coreCount Cores per token
    /// @param quantity Number of tokens
    /// @return canMint Whether wallet can perform the mint
    function canWalletMint(address wallet, uint8 coreCount, uint256 quantity) 
        external 
        view 
        returns (bool canMint) 
    {
        uint256 totalCoresNeeded = uint256(coreCount) * quantity;
        return walletCoreCount[wallet] + totalCoresNeeded <= maxCoresPerWallet &&
               totalMinted + quantity <= maxTotalSupply;
    }

    /// @notice Get progressive price preview from mint controller
    /// @param basePrice Base price per token
    /// @param coreCount Cores per token
    /// @param quantity Number of tokens
    /// @return totalPrice Total progressive price
    function getProgressivePrice(uint256 basePrice, uint8 coreCount, uint256 quantity) external view returns (uint256 totalPrice) {
        if (mintController == address(0)) revert InvalidConfiguration();
        return IConduitMintController(mintController).calculatePrice(basePrice, coreCount, quantity);
    }

    // View functions
    function getTokenConfig(uint256 tokenId) external view returns (TokenConfig memory) {
        return tokenConfigs[tokenId];
    }

    function isTokenExpired(uint256 tokenId) external view returns (bool) {
        return block.timestamp > tokenConfigs[tokenId].expiryDate;
    }

    // Admin functions
    function setCorePrice(uint8 coreCount, uint256 nativePrice, uint256 tokenPrice) 
        external 
        onlyOwner 
    {
        if (coreCount == 0 || coreCount > MAX_CORES_PER_TOKEN) revert InvalidCoreCount();
        _setCorePrice(coreCount, nativePrice, tokenPrice);
    }

    function setMintController(address _mintController) external onlyOwner {
        mintController = _mintController;
    }

    function setMaxCoresPerWallet(uint256 _maxCores) external onlyOwner {
        maxCoresPerWallet = _maxCores;
        emit MaxCoresPerWalletUpdated(_maxCores);
    }

    function setMaxTotalSupply(uint256 _maxTotalSupply) external onlyOwner {
        if (_maxTotalSupply < totalMinted) revert InvalidConfiguration();
        maxTotalSupply = _maxTotalSupply;
        emit MaxTotalSupplyUpdated(_maxTotalSupply);
    }

    function setPayableToken(address _payableToken) external onlyOwner {
        payableToken = _payableToken;
        emit PayableTokenSet(_payableToken);
    }

    function setRedemptionHandler(address handler) external onlyOwner {
        redemptionHandler = handler;
        emit RedemptionHandlerSet(handler);
    }

    function setTokenDescriptor(address descriptor) external onlyOwner {
        tokenDescriptor = descriptor;
        emit TokenDescriptorSet(descriptor);
    }

    function setDefaultExpiryDuration(uint256 duration) external onlyOwner {
        defaultExpiryDuration = duration;
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    function setTotalMinted(uint256 _totalMinted) external onlyOwner {
        if (_totalMinted > maxTotalSupply) revert InvalidConfiguration();
        totalMinted = _totalMinted;
        emit TotalMintedUpdated(_totalMinted);
    }

    function resetWalletCores(address wallet, uint256 newCoreCount) external onlyOwner {
        walletCoreCount[wallet] = newCoreCount;
    }

    function batchResetCores(
        address[] calldata wallets, 
        uint256[] calldata newCoreCounts
    ) external onlyOwner {
        if (wallets.length != newCoreCounts.length) revert InvalidConfiguration();
        
        for (uint256 i = 0; i < wallets.length; i++) {
            walletCoreCount[wallets[i]] = newCoreCounts[i];
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(amount);
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
    }

    // Internal functions
    function _mintSingle(address to, uint8 coreCount) internal {
        uint256 tokenId = nextTokenId++;
        uint256 expiryDate = block.timestamp + defaultExpiryDuration;

        tokenConfigs[tokenId] = TokenConfig({
            coreCount: coreCount,
            expiryDate: expiryDate,
            isActive: true
        });

        // Update tracking
        walletCoreCount[to] += coreCount;
        totalActiveSupply++;
        totalMinted++;
        
        _safeMint(to, tokenId);
        
        emit CoresMinted(tokenId, to, coreCount, expiryDate);
    }

    function _setCorePrice(uint8 coreCount, uint256 nativePrice, uint256 tokenPrice) internal {
        corePricing[coreCount] = CorePricing({
            nativePrice: nativePrice,
            tokenPrice: tokenPrice
        });
        
        emit CorePriceUpdated(coreCount, nativePrice, tokenPrice);
    }

    function _transferNative(address to, uint256 amount) internal {
        if (msg.value < amount) {
            revert InsufficientPayment();
        }
        
        // Transfer do treasury
        Address.sendValue(payable(to), amount);
        
        // Zwrot nadpłaty
        uint256 refund = msg.value - amount;
        if (refund > 0) {
            Address.sendValue(payable(msg.sender), refund);
        }
    }

    function _isAuthorizedForToken(address spender, uint256 tokenId) internal view returns (bool) {
        return spender == _ownerOf(tokenId) || 
               getApproved(tokenId) == spender || 
               isApprovedForAll(_ownerOf(tokenId), spender);
    }

    function _generateBasicTokenURI(uint256 tokenId) internal view returns (string memory) {
        TokenConfig memory config = tokenConfigs[tokenId];
        return string(abi.encodePacked(
            'data:application/json;utf8,{"name":"Yellow Conduit #',
            tokenId,
            '","description":"Entry to the Henomorphs Ecosystem","attributes":[{"trait_type":"Cores","value":',
            uint256(config.coreCount),
            '},{"trait_type":"Active","value":',
            config.isActive ? "true" : "false",
            '}]}'
        ));
    }

    function _addressToString(address addr) internal pure returns (string memory) {
        bytes32 value = bytes32(uint256(uint160(addr)));
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            str[i*2] = alphabet[uint8(value[i + 12] >> 4)];
            str[1+i*2] = alphabet[uint8(value[i + 12] & 0x0f)];
        }
        return string(str);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function _exists(uint256 tokenId) internal view returns (bool exists) {
        return tokenConfigs[tokenId].isActive;
    }

    /// @dev Override _update instead of deprecated _beforeTokenTransfer for OZ 5.x
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        
        // Update wallet core tracking on transfers
        if (from != address(0) && to != address(0) && from != to) {
            TokenConfig memory config = tokenConfigs[tokenId];
            if (config.isActive) {
                walletCoreCount[from] -= config.coreCount;
                walletCoreCount[to] += config.coreCount;
            }
        }
        
        return super._update(to, tokenId, auth);
    }

    // New events for added functionality
    event MaxCoresPerWalletUpdated(uint256 newMaxCores);
    event MaxTotalSupplyUpdated(uint256 newMaxTotalSupply);
    event TotalMintedUpdated(uint256 newTotalMinted);
    
    // Additional errors
    error SupplyExceeded();
}