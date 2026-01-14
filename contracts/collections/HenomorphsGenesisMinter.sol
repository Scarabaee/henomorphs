// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import "../interfaces/ICollectionMinter.sol";
import "../interfaces/IMintableCollection.sol";
import "../utils/IssueHelper.sol";
import "../utils/PrivilegedAccess.sol";
import "../utils/NativePriceQuoter.sol";
import "../common/MintingModel.sol";

interface ICollectionRepository {
    function getItemInfo(ItemType itemType, uint256 issueId, uint8 tier) external view returns (IssueInfo memory, ItemTier memory);
    function getDerivedItemPrice(ItemType itemType, uint256 issueId, uint8 tier, uint80[2] calldata rounds) external view returns (uint256, uint80[2] memory) ;
}

/**
 * @notice Contract module which provide a functionality to provide mint services for the ZicoDAOs collections.
 *.
 * @custom:website https://zicodao.io
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
contract HenomorphsGenesisMinter is Initializable, PausableUpgradeable, PrivilegedAccess, ReentrancyGuardUpgradeable, UUPSUpgradeable, ICollectionMinter {
    // Add the library methods
    using SafeERC20 for IERC20;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    IMintableCollection private collection;
    ICollectionRepository private collectionRepository;
    bytes32 private merkleRoot;

    /// @notice Timestamp at which minting starts
    uint256 private _mintPeriodStart;
    /// @notice Timestamp at which minting ends
    uint256 private _mintPeriodEnd;

    // Mapping for tracking mints
    mapping(address => uint256) private _totalCollected;

    // Mapping from issue ID to onchain boosts tokens per tier counter
    mapping(uint256 => mapping(uint8 => uint256)) private _mintCounters;

    /// @notice amount of tokens that can be minted by address
    mapping(uint8 => EnumerableMap.AddressToUintMap) private eligibleRecipients;
    /// @notice amount of tokens that can be minted freely by address
    mapping(uint8 => EnumerableMap.AddressToUintMap) private exemptedQuantities;

    // Mapping from issueId => tier => tier definition
    mapping(ItemType => mapping(uint256 => mapping(uint8 => MintInfo))) private _mintInfos;
    // Mapping from account to issue series per wallet counter 
    mapping(address => mapping(uint8 => uint256)) private _itemsCollected;
 
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address collectionContract, address repositoryContract, uint256 mintStartTiemstamp, uint256 mintEndTiemstamp) initializer public {
        __Pausable_init();
        __PrivilegedAccess_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        if (collectionContract == address(0)) {
            revert InvalidCollectionContract();
        }

        if (mintStartTiemstamp <= block.timestamp) {
            revert InvalidStartTimestamp();
        }

        if (mintEndTiemstamp <= mintStartTiemstamp) {
            revert InvalidEndTimestamp();
        }

        collection = IMintableCollection(collectionContract);
        collectionRepository = ICollectionRepository(repositoryContract);

        _mintPeriodStart = mintStartTiemstamp;
        _mintPeriodEnd = mintEndTiemstamp;
    }

    /**
     * @dev See {ITokenMinter-mintItems}.
     */
    function mintItems(MintRequest calldata request) public payable virtual nonReentrant whenNotPaused returns (uint256 quantity) {
        (IssueInfo memory issueInfo, ItemTier memory itemTier) = collectionRepository.getItemInfo(request.itemType, request.issueId, request.item.tier);
        
        if (issueInfo.issueId == 0) {
            revert InvalidIssueData();
        }

        if (!itemTier.isMintable) {
            revert ItemNotMintable(request.item.tier);
        }

        if (block.timestamp < _mintPeriodStart) {
            revert MintNotStarted();
        }

        if (block.timestamp > _mintPeriodEnd) {
            revert MintAlreadyEnded();
        }

        address _sender = _msgSender();
        address _recipient = (request.recipient != address(0) ? request.recipient : _sender);
        quantity = availability(request.itemType, request.issueId, request.item.tier, _sender);

        if (quantity == 0) {
            revert LimitAlreadyMinted();
        }
  
        if (merkleRoot != "") {
            bytes32 leaf = keccak256(abi.encodePacked(_sender, request.seed));
            bool valid = MerkleProof.verify(request.merkleProof, merkleRoot, leaf);

            if (!valid) {
                revert UnauthorizedClaim();
            }
        }

        MintInfo storage mintInfo = _mintInfos[request.itemType][request.issueId][request.item.tier];
        if (!mintInfo.isActive) {
            revert MintNotActive();
        }

        if (mintInfo.mintTier != itemTier.tier) {
            revert InvalidIssueData();
        }

        if (quantity > request.item.amount) {
            quantity = request.item.amount;
        }

        if (_mintCounters[mintInfo.issueId][mintInfo.mintTier] + quantity > mintInfo.maxSupply) {
            revert MintSupplyExceeded();
        }   

        uint256 _payableAmount = _requiredPayment(mintInfo, _sender, quantity, request.rounds);
        _acceptPayment(mintInfo.price.currency, _sender, _payableAmount, mintInfo.price.chargeNative);

        try collection.mintItems(request.issueId, request.item.tier, quantity, _recipient) returns (bool result) {
            if (!result) {
                revert ItemMintFailure(request, "Mint failed");
            }

            _transferTo(mintInfo.price.currency, mintInfo.price.beneficiary, _payableAmount, mintInfo.price.chargeNative);

            unchecked {
                _mintCounters[mintInfo.issueId][mintInfo.mintTier] += quantity;
                _itemsCollected[_sender][mintInfo.mintTier] += quantity; 
                _totalCollected[_sender] += 1;        
            }

            emit ItemsMinted(request.issueId, request.item.tier, quantity, request.itemType, _sender);
        } catch {
            revert ItemMintFailure(request, "Mint failed");
        }
    }

    /**
     * @dev See {ICollectionMinter-availability}.
     */
    function availability(ItemType itemType, uint256 issueId, uint8 tier, address recipient) public view returns (uint256) {  
        MintInfo storage mintInfo = _mintInfos[itemType][issueId][tier];
        (, ItemTier memory itemTier) = collectionRepository.getItemInfo(mintInfo.itemType, mintInfo.issueId, mintInfo.mintTier);

        if (itemTier.tier != tier) {
            return 0;
        }

        uint256 _itemsMinted =  collection.collectedOf(recipient, issueId, tier);
        uint256 quantity = 0;

        if (mintInfo.maxMints > _itemsMinted) {
            quantity = mintInfo.maxMints - _itemsMinted;
        } 

        unchecked {
            if (eligibleRecipients[tier].length() > 0) {
                if (eligibleRecipients[tier].contains(recipient)) {
                    if (eligibleRecipients[tier].get(recipient) >= _itemsMinted) {
                        quantity = eligibleRecipients[tier].get(recipient) - _itemsMinted;
                    }
                } else {
                    if (merkleRoot != "") {
                        quantity = 0 ;
                    }
                }
            }

            uint256 _totalMinted = _mintCounters[mintInfo.issueId][mintInfo.mintTier];
            if (quantity > 0) {
                if (_totalMinted + quantity > mintInfo.maxSupply) {
                    quantity = mintInfo.maxSupply - _totalMinted;
                }

                if (_totalMinted + quantity > itemTier.maxSupply) {
                    quantity = itemTier.maxSupply - _totalMinted;
                }
            }
        }

        return quantity;
    }

    /**
     * @dev See {ICollectionMinter-mintSupply}. 
     */
    function mintSupply(ItemType itemType, uint256 issueId, uint8 tier) external view returns (uint256) {
        return _mintInfos[itemType][issueId][tier].maxSupply; 
    }

    /**
     * @dev See {ICollectionMinter-totalMinted}. 
     */    
    function totalMinted(ItemType, uint256 issueId, uint8 tier) external view returns (uint256) {
        return _mintCounters[issueId][tier];
    }

    /**
     * @dev See {ICollectionMinter-mintedOf}. 
     */    
    function mintedOf(ItemType, uint256, uint8 tier, address recipient) external view returns (uint256) {
        return _itemsCollected[recipient][tier];
    }

    /**
     * @dev See {ICollectionMinter-derivePrice}. 
     */    
    function derivePrice(ItemType itemType, uint256 issueId, uint8 tier, uint80[2] calldata rounds) external view returns (uint256, uint80[2] memory) {
        MintInfo storage mintInfo = _mintInfos[itemType][issueId][tier];
        return _derivePrice(mintInfo, rounds);
    }

    /**
     * @dev See {ICollectionMinter-getMintInfo}. 
     */
    function getMintInfo(ItemType itemType, uint256 issueId, uint8 tier) external view returns (MintInfo memory) {
        return _mintInfos[itemType][issueId][tier];
    }

    /**
     * @dev Allows to define or overwrite if already exists the mint definition data.
     */
    function defineMintInfos(uint256 issueId, ItemType itemType, MintInfo[] calldata infos) external onlyPrivileged {
        for (uint256 i = 0; i < infos.length; i++) {
            if (infos[i].itemType != itemType || infos[i].issueId != issueId) {
                revert InvalidCallData();
            }

            _mintInfos[itemType][issueId][infos[i].mintTier] = MintInfo(infos[i].itemType, infos[i].issueId, infos[i].mintTier, infos[i].maxSupply, infos[i].maxMints, infos[i].freeMints, infos[i].price, infos[i].onSale, infos[i].isPayable, infos[i].isActive);
        }
    }

    /**
     * @dev Allows to overwrite if already exists the mint data.
     */
    function deleteMintInfos(uint256 issueId, ItemType itemType, MintInfo[] calldata infos) external onlyPrivileged {
        for (uint256 i = 0; i < infos.length; i++) {
            delete _mintInfos[itemType][issueId][infos[i].mintTier];
        }
    }

    /// @notice Allows owner to set a list of recipients to receive tokens.
    /// @dev This may need to be called many times to set the full list of recipients.
    function setEligibleRecipients(uint8 tier, address[] calldata recipients, uint256[] calldata amounts) external onlyPrivileged {
        if (recipients.length != amounts.length) {
            revert InvalidCallData();
        }

        for (uint256 i = 0; i < recipients.length; i++) {
            eligibleRecipients[tier].set(recipients[i], amounts[i]);
        }
    }

    /// @notice Allows owner to reset the eligible recipients list.
    function clearEligibleRecipients(uint8 tier, bool reset) external onlyPrivileged {
        address[] memory recipients = eligibleRecipients[tier].keys();

        for (uint256 i = 0; i < recipients.length; i++) {
            eligibleRecipients[tier].remove(recipients[i]);
            
            if (reset) {
                delete _itemsCollected[recipients[i]][tier];
            }
        }
    }

    /// @notice Allows to check wether given `recipient` is eligible.
    /// @dev returns Number greater then `0` if the `recipient` is eligible, `0` otherwise.
    function isRecipientEligible(uint8 tier, address recipient) external view returns (uint256) {
        unchecked {
            if (!eligibleRecipients[tier].contains(recipient)) {
                return 0;
            }
        }
        return eligibleRecipients[tier].get(recipient);
    }

    /// @notice Allows owner to set a list of recipients to receive tokens.
    /// @dev This may need to be called many times to set the full list of recipients.
    function setExemptedQuantities(uint8 tier, address[] calldata recipients, uint256[] calldata exemptedAmounts) external onlyPrivileged {
        if (recipients.length != exemptedAmounts.length) {
            revert InvalidCallData();
        }

        for (uint256 i = 0; i < recipients.length; i++) {
            exemptedQuantities[tier].set(recipients[i], exemptedAmounts[i]);
        }
    }

    /// @notice Allows owner to reset the eligible recipients list.
    function clearExemptedQuantities(uint8 tier) external onlyPrivileged {
        address[] memory recipients = exemptedQuantities[tier].keys();

        for (uint256 i = 0; i < recipients.length; i++) {
            exemptedQuantities[tier].remove(recipients[i]);
        }
    }

    /// @notice Allows to check wether given `recipient` is allowed to claim freely.
    /// @dev returns Number greater then `0` if the `recipient` is eligible for free clain, `0` otherwise.
    function getExemptedQuantity(uint8 tier, address recipient) external view returns (uint256) {
        unchecked {
            if (!exemptedQuantities[tier].contains(recipient)) {
                return 0;
            }
        }
        return exemptedQuantities[tier].get(recipient);
    }

    /// @notice Allows to update the start of the mint.
    function setMintPeriodStart(uint256 timestamp) public onlyPrivileged {
        if (timestamp <= block.timestamp) {
            revert InvalidStartTimestamp();
        }

        _mintPeriodStart = timestamp;
    }

    /// @notice Allows to update the end of the claim.
    function setMintPeriodEnd(uint256 timestamp) public onlyPrivileged {
        if (timestamp <= _mintPeriodStart) {
            revert InvalidEndTimestamp();
        }

        _mintPeriodEnd = timestamp;
    }

    /*
     * @dev Sets the new merkle root.
     * @param newRoot The merkle root to set.
     */
    function setMerkleRoot(bytes32 newRoot) public onlyPrivileged {
        merkleRoot = newRoot;
    }

    /**
     * @dev Allows to setup a new minting collection contracts.
     * @param collectionContract A address to set for the new collection contract.
     * @param repositoryContract A address to set for the new repository contract.
     */
    function updateMintContracts(address collectionContract, address repositoryContract) external onlyPrivileged {
        if (collectionContract == address(0) || repositoryContract == address(0)) {
            revert InvalidCallData();
        }

        collection = IMintableCollection(collectionContract);
        collectionRepository = ICollectionRepository(repositoryContract);
    }

    function pause() public onlyPrivileged {
        _pause();
    }

    function unpause() public onlyPrivileged {
        _unpause();
    }

    // ************************************* 
    // Utility methods
    // *************************************

    function _requiredPayment(MintInfo storage mintInfo, address sender, uint256 quantity, uint80[2] memory rounds) internal virtual returns (uint256 subtotal) {
        if (mintInfo.isPayable || mintInfo.price.regular > 0) {
            uint256 _itemsMinted = _itemsCollected[sender][mintInfo.mintTier];
            uint256 _freeMints = mintInfo.freeMints;

            unchecked {
                if (exemptedQuantities[mintInfo.mintTier].length() > 0) {
                    if (exemptedQuantities[mintInfo.mintTier].contains(sender)) {
                        _freeMints = exemptedQuantities[mintInfo.mintTier].get(sender);
                    }
                }

                _freeMints = (_freeMints > _itemsMinted) ? (_freeMints - _itemsMinted) : 0;
                (uint256 _price, ) = _derivePrice(mintInfo, rounds);

                subtotal = (quantity > _freeMints) ? (_price * (quantity- _freeMints)) : 0;
            }
        }
    }

    function _derivePrice(MintInfo storage mintInfo, uint80[2] memory rounds) internal virtual view returns (uint256 _price, uint80[2] memory _rounds) {
        _price = (mintInfo.onSale ? mintInfo.price.discounted : mintInfo.price.regular);

        if (mintInfo.price.chargeNative) {
            (_price, _rounds) = NativePriceQuoter.derivedPrice(_price, rounds);
        } 
    }

    function _isNativeToken(IERC20 currency) internal view virtual returns (bool) {
        return address(currency) == address(0);
    }

   function _acceptPayment(IERC20 currency, address from, uint256 amount, bool chargeNative) internal virtual returns (uint256) {
        if (amount > 0) {
            if (_isNativeToken(currency) || chargeNative) {
                return amount;
            } else {
                currency.safeTransferFrom(from, address(this), amount);
            }
        }
        return 0;
    }

    function _transferTo(IERC20 currency, address to, uint256 amount, bool chargeNative) internal virtual {
        if (amount > 0) {
            if (_isNativeToken(currency) || chargeNative) {
                _checkout(to, amount);
            } else {
                currency.safeTransfer(to, amount);
            }
        } else {
            if (msg.value > 0) {
                Address.sendValue(payable(_msgSender()), msg.value);
            }
        }
    }

    function _checkout(address beneficiary, uint256 amount) internal virtual {
        if (msg.value < amount) {
            revert InsufficientValueSent(msg.value);
        }
        Address.sendValue(payable(beneficiary), amount);
        Address.sendValue(payable(_msgSender()), msg.value - amount);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyPrivileged
        override
    {}
}