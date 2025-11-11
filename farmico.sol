// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract Farmico is ERC20, AccessControl, Pausable {	

    // Address of contract allowed to burn tokens
    address public burnerContract;

    // Roles
    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");   // Admin role
    bytes32 private constant ROLE_OWNER = keccak256("ROLE_OWNER");   // Super-owner role

    // Events
    event BurnerUpdated(address indexed newBurner);
    event TokensMinted(address indexed to, uint256 amount, address caller);
    event TokensBurned(address indexed from, uint256 amount, address caller);
    event OwnerUpdated(address oldOwner, address newOwner);
    event AdminAdded(address admin);
    event AdminRemoved(address admin);

    constructor(string memory name, string memory symbol) 
        ERC20(name, symbol) 
    {
        // Deployer gets full rights
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ROLE_OWNER, msg.sender);

        // Only owner can add/remove admins
        _setRoleAdmin(ADMIN_ROLE, ROLE_OWNER);
    }

    // Restricts to admins only
    modifier adminOnly() {
        require(
            hasRole(ADMIN_ROLE, msg.sender),
            "Not allowed: Caller is not an admin"
        );
        _;
    }

    // Pause all transfers, minting, burning
    function pause() external onlyRole(ROLE_OWNER) {
        _pause();
    }

    // Unpause contract
    function unpause() external onlyRole(ROLE_OWNER) {
        _unpause();
    }

    // Set external burner contract (only admin)
    function setBurnerContract(address _burner) external adminOnly whenNotPaused {
        require(_burner != address(0), "Invalid burner address");
        burnerContract = _burner;
        emit BurnerUpdated(_burner);
    }

    // Burn tokens from an account (only burnerContract can call)
    function burnFrom(address account, uint256 amount) external whenNotPaused {
        require(msg.sender == burnerContract, "Not authorized to burn");
        _burn(account, amount);
        emit TokensBurned(account, amount, msg.sender);
    }

    // Mint new tokens (only admin)
    function mint(address to, uint256 amount) external adminOnly whenNotPaused {
        require(to != address(0), "Input is a zero address");
        _mint(to, amount);
        emit TokensMinted(to, amount, msg.sender);
    }

    // Grant ADMIN role (only owner)
    function addAdmin(address account) external onlyRole(ROLE_OWNER) {
        grantRole(ADMIN_ROLE, account);
        emit AdminAdded(account);
    }

    // Revoke ADMIN role (only owner)
    function removeAdmin(address account) external onlyRole(ROLE_OWNER) {
        revokeRole(ADMIN_ROLE, account);
        emit AdminRemoved(account);
    }
    
    // Transfer ownership to new account (revokes from old owner)
    function updateOwner(address newOwner) external onlyRole(ROLE_OWNER) {
        require(newOwner != address(0), "Zero address not allowed");
        address oldOwner = msg.sender;
        _revokeRole(DEFAULT_ADMIN_ROLE, oldOwner);
        _revokeRole(ROLE_OWNER, oldOwner);
        _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
        _grantRole(ROLE_OWNER, newOwner);
        emit OwnerUpdated(oldOwner, newOwner);
    }
}
