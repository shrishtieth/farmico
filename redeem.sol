// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFarmico {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function burnFrom(address account, uint256 amount) external;
}

contract RedeemAndBurn is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IFarmico public token;

    // Roles
    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");   // Admin can redeem tokens
    bytes32 private constant ROLE_OWNER = keccak256("ROLE_OWNER");   // Owner can manage admins and rescue tokens

    // Events
    event Redeemed(address indexed user, bytes32 indexed storeManager, uint256 amount, uint256 timestamp);
    event OwnerUpdated(address oldOwner, address newOwner);
    event AdminAdded(address admin);
    event AdminRemoved(address admin);
    event TokensWithdrawn(address token, address to, uint256 amount);

    constructor(address _token) {
        require(_token != address(0), "Token is a zero address");
        token = IFarmico(_token);

        // Deployer gets owner privileges
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ROLE_OWNER, msg.sender);

        // Only owner can manage admins
        _setRoleAdmin(ADMIN_ROLE, ROLE_OWNER);
    }

    // Modifier to restrict function to admins
    modifier adminOnly() {
        require(hasRole(ADMIN_ROLE, msg.sender), "Caller is not an admin");
        _;
    }

    // Pause/unpause contract
    function pause() external onlyRole(ROLE_OWNER) {
        _pause();
    }

    function unpause() external onlyRole(ROLE_OWNER) {
        _unpause();
    }

    // Admin management
    function addAdmin(address account) external onlyRole(ROLE_OWNER) {
        grantRole(ADMIN_ROLE, account);
        emit AdminAdded(account);
    }

    function removeAdmin(address account) external onlyRole(ROLE_OWNER) {
        revokeRole(ADMIN_ROLE, account);
        emit AdminRemoved(account);
    }

    // Transfer ownership
    function updateOwner(address newOwner) external onlyRole(ROLE_OWNER) {
        require(newOwner != address(0), "Zero address not allowed");
        address oldOwner = msg.sender;

        _revokeRole(DEFAULT_ADMIN_ROLE, oldOwner);
        _revokeRole(ROLE_OWNER, oldOwner);
        _grantRole(DEFAULT_ADMIN_ROLE, newOwner);
        _grantRole(ROLE_OWNER, newOwner);

        emit OwnerUpdated(oldOwner, newOwner);
    }

    // Redeem tokens from a user
    function redeem(address farmer, uint256 amount, bytes32 storeManager)
        external
        adminOnly
        whenNotPaused
        nonReentrant
    {
        require(amount > 0, "Amount must be greater than zero");
        require(farmer != address(0), "Farmer is a zero address");
        token.burnFrom(farmer, amount);
        emit Redeemed(farmer, storeManager, amount, block.timestamp);
    }

    // Rescue ERC20 tokens sent by mistake
    function rescueERC20(address _token, address to, uint256 amount) external onlyRole(ROLE_OWNER) {
        require(to != address(0), "Zero address not allowed");
        require(amount > 0, "Amount must be greater than zero");
        IERC20(_token).safeTransfer(to, amount);
        emit TokensWithdrawn(_token, to, amount);
    }
}
