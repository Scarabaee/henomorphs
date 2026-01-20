
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../libraries/CollectionModel.sol";

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an additional administrative account (an admin) that can be granted exclusive access to
 * specific functions.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyPrivileged`, which can be applied to your functions to restrict their use to
 * the owner and admin addresses.
 *
 * @author rutilicus.eth (ArchXS)
 * @custom:security-contact contact@archxs.com
 */
abstract contract PrivilegedAccess is Initializable, ContextMixin, OwnableUpgradeable {

    address internal _admin; 

    event PrivilegesTransferred(address indexed previousAdmin, address indexed newAdmin);

    /**
     * @dev Initializes the contract setting the deployer as the initial admin.
     */
    function __PrivilegedAccess_init() internal onlyInitializing {
        __PrivilegedAccess_init_unchained(_msgSender());
    }

    function __PrivilegedAccess_init_unchained(address initialOwner) internal onlyInitializing {
        __Ownable_init(initialOwner);
        _transferPrivileges(initialOwner);
    }

    /**
     * @dev Returns the address of the current admin.
     */
    function admin() public view virtual returns (address) {
        return _admin;
    }

    /**
     * @dev Transfers administrative privileges of the contract to a new account (`newAdmin`).
     * Can only be called by the current owner and admin.
     */
    function transferPrivileges(address newAdmin) public virtual onlyOwner {
        require(newAdmin != address(0), "Invalid admin address");
        _transferPrivileges(newAdmin);
    }

    // *************************************
    // Modifiers
    // ************************************* 

    /**
     * @dev Throws if called by any account other than the priviledged ones.
     */
    modifier onlyPrivileged() {
        _checkPrivileged();
        _;
    }

    /**
     * @dev Throws if called by a contract
     */
    modifier nonContract() {
        require(tx.origin == _msgSender(), "Call forbidden");
        _;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkPrivileged() internal view virtual {
        address _sender = _msgSender();
        require(_admin == _sender || owner() == _sender, "Caller is not privileged");
    }

    /**
     * @dev Transfers administration of the contract to a new account (`newAdmin`).
     * Internal function without access restriction.
     */
    function _transferPrivileges(address newAdmin) internal virtual {
        address oldAdmin = _admin;
        _admin = newAdmin;
        emit PrivilegesTransferred(oldAdmin, newAdmin);
    }
}