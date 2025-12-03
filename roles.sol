// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title RolesManager
/// @notice Manage roles: Buyer (1), Seller (2), Admin (3), SuperAdmin (4)
contract RolesManager {
    enum Role { None, Buyer, Seller, Admin, SuperAdmin }

    mapping(address => Role) public roles;
    address public superAdmin;

    event RoleGranted(address indexed account, Role role);
    event RoleRevoked(address indexed account, Role role);

    modifier onlySuperAdmin() {
        require(msg.sender == superAdmin, "Only super admin");
        _;
    } 

    constructor(address initialSuperAdmin) {
        require(initialSuperAdmin != address(0), "zero address");
        superAdmin = initialSuperAdmin;
        roles[initialSuperAdmin] = Role.SuperAdmin;
        emit RoleGranted(initialSuperAdmin, Role.SuperAdmin);
    }

    /// @notice Grant role. Admin/SuperAdmin rules enforced.
    function grantRole(address account, Role role) external {
        require(account != address(0), "zero address");

        if (role == Role.SuperAdmin || role == Role.Admin) {
            // only superAdmin can grant Admin or SuperAdmin
            require(msg.sender == superAdmin, "Only superAdmin grants Admin/SuperAdmin");
        } else {
            // Seller/Buyer can be granted by Admin or SuperAdmin
            require(roles[msg.sender] == Role.Admin || msg.sender == superAdmin, "Only admin/superAdmin");
        }

        roles[account] = role;
        emit RoleGranted(account, role);
    }

    /// @notice Revoke role with same permission model
    function revokeRole(address account) external {
        require(account != address(0), "zero address");
        Role r = roles[account];
        require(r != Role.None, "account has no role");

        if (r == Role.Admin || r == Role.SuperAdmin) {
            require(msg.sender == superAdmin, "Only superAdmin can revoke Admin/SuperAdmin");
        } else {
            require(roles[msg.sender] == Role.Admin || msg.sender == superAdmin, "Only admin/superAdmin");
        }

        roles[account] = Role.None;
        emit RoleRevoked(account, r);
    }

    /// @notice Query helper: external callers pass role as uint8 (1..4).
    function hasRole(address account, uint8 role) external view returns (bool) {
        if (role == uint8(Role.Admin)) {
            return roles[account] == Role.Admin || roles[account] == Role.SuperAdmin;
        }
        if (role == uint8(Role.SuperAdmin)) {
            return roles[account] == Role.SuperAdmin;
        }
        return uint8(roles[account]) == role;
    }

    /// @notice Change superAdmin (only current superAdmin)
    function changeSuperAdmin(address newSuperAdmin) external onlySuperAdmin {
        require(newSuperAdmin != address(0), "zero address");
        roles[superAdmin] = Role.None;
        emit RoleRevoked(superAdmin, Role.SuperAdmin);

        superAdmin = newSuperAdmin;
        roles[newSuperAdmin] = Role.SuperAdmin;
        emit RoleGranted(newSuperAdmin, Role.SuperAdmin);
    }
}

