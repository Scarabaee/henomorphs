// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @notice Structs and enums module which provides a model of the PCS collections. 
 *
 * @custom:website https://nft.poczta-polska.pl
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */

/**
 * https://github.com/maticnetwork/pos-portal/blob/master/contracts/common/ContextMixin.sol
 */
abstract contract ContextMixin is Initializable {

    function __ContextMixin_init() internal onlyInitializing {
    }

    function __ContextMixin_init_unchained() internal onlyInitializing {
    }

    function msgSender()
        internal
        view
        returns (address payable sender)
    {
        if (msg.sender == address(this)) {
            bytes memory array = msg.data;
            uint256 index = msg.data.length;
            assembly {
                // Load the 32 bytes word from memory with the address on the lower 20 bytes, and mask those.
                sender := and(
                    mload(add(array, index)),
                    0xffffffffffffffffffffffffffffffffffffffff
                )
            }
        } else {
            sender = payable(msg.sender);
        }
        return sender;
    }
}

bytes1 constant SLASH = 0x2f;

/**
* @dev Structure used to define the selling phases of the series collections.
*/
enum IssuePhase {
    Locked,
    Affiliate,
    Limited,
    Presale,
    General,
    Stunt
}

/**
* @dev Structure used to define the type of collection items.
*/
enum ItemType {
    Thaler,
    Stamp,
    Vignette,
    Envelope,
    Folder,
    Card,
    Other
}

/**
* @dev Structure used to mint/deposit tokens.
*/
struct Depositary {
    // The adres of target wallet
    address wallet;
    // In case of batch minting
    // The serial offset number of the wallet in the given category
    uint256 offset;
    // In case of batch minting to depositary wallet
    // The batch size to process 
    uint256 limit;
    // In case of minting tokens
    // The amount of tokens to mint
    uint256 amount;
    // In case of batch minting to different wallets
    // The pre-computed tokenID number, used if > 0
    uint256 serial;
}

/**
 * @dev Struct that keeps miniseries specific properties.
 */
struct IssueInfo {
    // Issue ID, subsequent number of the series 
    uint256 issueId;
    // The type of item to define
    ItemType itemType;
    // The designation of the series eg. S1
    string designation;
    // The address the tokens or withdrowals maight be deposited
    address beneficiary;
    // The number of tiers supported by the series.
    uint256 tiersCount;
    // The base eg. hidden metadata URI
    string baseUri;
    // Whether the sessies config can be still modified
    bool isFixed;
    // When the targed uri should be revealed, the issue date
    uint256 issueTimestamp;
    // The current general issue phase of the series
    IssuePhase issuePhase;
}

/**
 * @dev Struct that keeps issue tiers item specific properties.
 */
struct ItemTier {
    // One of the tiers defined by the collection
    uint8 tier;
    // The base metadata URI of the given issue tier
    string tierUri;
    // Max items supply
    uint256 maxSupply;
    // The base quote token price
    uint256 price;
    // Max available mint per wallet
    uint256 maxMints;
    // Whether the thaler is mintable 
    bool isMintable;
    // Whether the thaler is swappable to stamp
    bool isSwappable;
    // Whether the thaler is swappable to stamp
    bool isBoostable;
    // When the target uri should be revealed for a given tier
    uint256 revealTimestamp;
    // The initial serial number for token ids
    uint256 offset;
    // The last serial number for token ids
    uint256 limit;
    // Wheter the ids enumeration is sequential
    bool isSequential;
    // The posible tier vatiants number
    uint256 variantsCount;
    // The specific features bitmap
    uint256 features;
}

/**
 * @dev Struct that keeps items tier variants specific properties.
 */
struct TierVariant {
    // One of the variants defined by the tier
    uint8 variant;
    // One of the tiers defined by the collection
    uint8 tier;
    // Max varoant supply
    uint256 maxSupply;
}

/**
 * @dev Struct that keeps issue phase specific properties.
 */
struct PhaseInfo {
    // The current general issue phase of the series
    IssuePhase phase;
    // Block timestamp or number at which phase starts
    uint256 phaseStart;
    // Block timestamp or number at which phase ends
    uint256 phaseEnd;
    // Merkle root if access is limited
    bytes32 merkleRoot;
    // The number of stamps/tokens available in the given phase
    uint256 maxSupply;
    // Max available mint per wallet
    uint256 maxMints;
    // The token price discount for onchain sale
    uint256 discount;
    // Whether the phase settings are applicable
    bool isActive;
    // The specific features bitmap
    uint256 features;
}


