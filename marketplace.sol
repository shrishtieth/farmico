// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract FarmicoMarketplace is ERC721 {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIdCounter;

    enum NFTStatus { Active, Claimed, Revoked }

    // tokenId => tradeId
    mapping(uint256 => uint256) public tokenTrade;
    // tokenId => status
    mapping(uint256 => NFTStatus) public tokenStatus;
    // tokenId => mintedAt
    mapping(uint256 => uint256) public tokenMintedAt;

    // per-token URI storage (OZ v5 style)
    mapping(uint256 => string) private _tokenURIs;

    event NFTMinted(uint256 indexed tokenId, uint256 indexed tradeId, address indexed owner);
    event NFTMetadataUpdated(uint256 indexed tokenId, string oldURI, string newURI);
    event NFTStatusChanged(uint256 indexed tokenId, NFTStatus oldStatus, NFTStatus newStatus);

    // --- Roles ---
    enum Role { None, Buyer, Seller, Admin, SuperAdmin }
    mapping(address => Role) public roles;
    address public superAdmin;

    // --- Counters ---
    uint256 private _requestIdCounter;
    uint256 private _commodityIdCounter;
    uint256 private _tradeIdCounter;

    // --- Request flow ---
    enum RequestStatus { Pending, Approved, Rejected, Cancelled }
    struct ListingRequest {
        uint256 id;
        address seller;
        string title;
        string description;
        string category;
        uint256 quantity;
        uint256 pricePerUnit;
        uint256 createdAt;
        RequestStatus status;
        string adminNotes;
    }
    mapping(uint256 => ListingRequest) public listingRequests;
    mapping(address => uint256[]) public sellerRequests;

    // --- Commodities ---
    enum CommodityStatus { Inactive, Active, SoldOut, Removed }
    struct Commodity {
        uint256 id;
        address seller;
        string title;
        string category;
        uint256 totalQuantity;
        uint256 remainingQuantity;
        uint256 pricePerUnit;
        CommodityStatus status;
        string currentStage;
        string location;
        string misc;
        uint256 createdAt;
    }
    mapping(uint256 => Commodity) public commodities;
    mapping(address => uint256[]) public sellerCommodities;

    // --- Trades ---
    struct TradeRecord {
        uint256 id;
        uint256 commodityId;
        address buyer;
        address seller;
        uint256 quantity;
        uint256 pricePerUnit;
        uint256 totalPrice;
        uint256 timestamp;
        string offchainReference;
    }
    mapping(uint256 => TradeRecord) public trades;
    mapping(uint256 => uint256[]) public commodityTrades;
    mapping(address => uint256[]) public buyerTrades;

    // --- Events ---
    event RoleGranted(address indexed account, Role role);
    event RoleRevoked(address indexed account, Role role);

    event ListingRequested(uint256 indexed requestId, address indexed seller);
    event ListingApproved(uint256 indexed requestId, uint256 indexed commodityId);
    event ListingRejected(uint256 indexed requestId, string reason);
    event ListingCancelled(uint256 indexed requestId);

    event CommodityStageUpdated(uint256 indexed commodityId, string stage, string location, string misc);
    event CommodityStatusChanged(uint256 indexed commodityId, CommodityStatus status);

    event TradeRecorded(uint256 indexed tradeId, uint256 indexed commodityId, address indexed buyer, uint256 quantity);

    // --- Modifiers ---
    modifier onlySuperAdmin() {
        require(msg.sender == superAdmin, "Only super admin");
        _;
    }

    modifier onlyAdmin() {
        require(roles[msg.sender] == Role.Admin || msg.sender == superAdmin, "Only admin or super admin");
        _;
    }

    modifier onlySeller() {
        require(roles[msg.sender] == Role.Seller, "Only seller role");
        _;
    }

    modifier onlyBuyer() {
        require(
            roles[msg.sender] == Role.Buyer ||
            roles[msg.sender] == Role.Seller ||
            roles[msg.sender] == Role.Admin ||
            msg.sender == superAdmin,
            "Only buyer role"
        );
        _;
    }

    // --- Constructor: initialize ERC721 name & symbol ---
    constructor(address initialSuperAdmin) ERC721("Farmico Trade NFT", "FTN") {
        require(initialSuperAdmin != address(0), "superAdmin cannot be zero");
        superAdmin = initialSuperAdmin;
        roles[initialSuperAdmin] = Role.SuperAdmin;
        emit RoleGranted(initialSuperAdmin, Role.SuperAdmin);
    }

    // --- Role management ---
    function grantRole(address account, Role role) external {
        require(account != address(0), "zero address");

        if (role == Role.SuperAdmin || role == Role.Admin) {
            require(msg.sender == superAdmin, "Only superAdmin grants Admin or SuperAdmin");
        } else {
            require(roles[msg.sender] == Role.Admin || msg.sender == superAdmin, "Only admin or superAdmin can grant this role");
        }

        roles[account] = role;
        emit RoleGranted(account, role);
    }

    function revokeRole(address account) external {
        require(account != address(0), "zero address");
        Role r = roles[account];
        require(r != Role.None, "account has no role");

        if (r == Role.Admin || r == Role.SuperAdmin) {
            require(msg.sender == superAdmin, "Only superAdmin can revoke Admin or SuperAdmin");
        } else {
            require(roles[msg.sender] == Role.Admin || msg.sender == superAdmin, "Only admin or superAdmin can revoke this role");
        }

        roles[account] = Role.None;
        emit RoleRevoked(account, r);
    }

    function hasRole(address account, Role role) public view returns (bool) {
        if (role == Role.Admin) {
            return roles[account] == Role.Admin || roles[account] == Role.SuperAdmin;
        }
        if (role == Role.SuperAdmin) return roles[account] == Role.SuperAdmin;
        return roles[account] == role;
    }

    // --- Listing requests ---
    function requestListing(
        string calldata title,
        string calldata description,
        string calldata category,
        uint256 quantity,
        uint256 pricePerUnit
    ) external onlySeller returns (uint256) {
        require(quantity > 0, "quantity must be > 0");
        require(bytes(title).length > 0, "title required");

        _requestIdCounter++;
        uint256 rid = _requestIdCounter;

        listingRequests[rid] = ListingRequest({
            id: rid,
            seller: msg.sender,
            title: title,
            description: description,
            category: category,
            quantity: quantity,
            pricePerUnit: pricePerUnit,
            createdAt: block.timestamp,
            status: RequestStatus.Pending,
            adminNotes: ""
        });

        sellerRequests[msg.sender].push(rid);
        emit ListingRequested(rid, msg.sender);
        return rid;
    }

    function cancelListingRequest(uint256 requestId) external {
        ListingRequest storage r = listingRequests[requestId];
        require(r.id != 0, "request not found");
        require(r.seller == msg.sender, "only seller can cancel");
        require(r.status == RequestStatus.Pending, "can only cancel pending requests");

        r.status = RequestStatus.Cancelled;
        emit ListingCancelled(requestId);
    }

    // --- Admin review ---
    function approveListingRequest(uint256 requestId, string calldata adminNote) external onlyAdmin returns (uint256) {
        ListingRequest storage r = listingRequests[requestId];
        require(r.id != 0, "request not found");
        require(r.status == RequestStatus.Pending, "request not pending");

        r.status = RequestStatus.Approved;
        r.adminNotes = adminNote;

        // create commodity
        _commodityIdCounter++;
        uint256 cid = _commodityIdCounter;

        commodities[cid] = Commodity({
            id: cid,
            seller: r.seller,
            title: r.title,
            category: r.category,
            totalQuantity: r.quantity,
            remainingQuantity: r.quantity,
            pricePerUnit: r.pricePerUnit,
            status: CommodityStatus.Active,
            currentStage: "Created",
            location: "",
            misc: "",
            createdAt: block.timestamp
        });

        sellerCommodities[r.seller].push(cid);
        emit ListingApproved(requestId, cid);
        return cid;
    }

    function rejectListingRequest(uint256 requestId, string calldata reason) external onlyAdmin {
        ListingRequest storage r = listingRequests[requestId];
        require(r.id != 0, "request not found");
        require(r.status == RequestStatus.Pending, "request not pending");

        r.status = RequestStatus.Rejected;
        r.adminNotes = reason;
        emit ListingRejected(requestId, reason);
    }

    function updateListingRequest(
    uint256 requestId,
    string calldata title,
    string calldata description,
    string calldata category,
    uint256 quantity,
    uint256 pricePerUnit
    ) external onlySeller {
    ListingRequest storage r = listingRequests[requestId];
    require(r.id != 0, "request not found");
    require(r.seller == msg.sender, "not your request");
    require(r.status == RequestStatus.Pending, "only pending editable");

    r.title = title;
    r.description = description;
    r.category = category;
    r.quantity = quantity;
    r.pricePerUnit = pricePerUnit;
    }

    function updateListingAdminNotes(uint256 requestId, string calldata notes) external onlyAdmin {
    ListingRequest storage r = listingRequests[requestId];
    require(r.id != 0, "request not found");
    r.adminNotes = notes;
    }

    // --- Commodity lifecycle updates ---
    function updateCommodityStage(
        uint256 commodityId,
        string calldata stage,
        string calldata location,
        string calldata misc
    ) external {
        Commodity storage c = commodities[commodityId];
        require(c.id != 0, "commodity not found");
        require(c.status == CommodityStatus.Active, "commodity not active");

        require(msg.sender == c.seller || roles[msg.sender] == Role.Admin || msg.sender == superAdmin, "not authorized to update commodity stage");

        c.currentStage = stage;
        c.location = location;
        c.misc = misc;
        emit CommodityStageUpdated(commodityId, stage, location, misc);
    }

    function changeCommodityStatus(uint256 commodityId, CommodityStatus newStatus) external {
        Commodity storage c = commodities[commodityId];
        require(c.id != 0, "commodity not found");

        require(msg.sender == c.seller || roles[msg.sender] == Role.Admin || msg.sender == superAdmin, "not authorized");
        c.status = newStatus;
        emit CommodityStatusChanged(commodityId, newStatus);
    }

    function updateCommodityDetails(
    uint256 commodityId,
    string calldata title,
    string calldata category,
    uint256 pricePerUnit,
    string calldata misc
    ) external {
    Commodity storage c = commodities[commodityId];
    require(c.id != 0, "commodity not found");

    require(msg.sender == c.seller || roles[msg.sender] == Role.Admin || msg.sender == superAdmin,
        "not authorized");

    c.title = title;
    c.category = category;
    c.pricePerUnit = pricePerUnit;
    c.misc = misc;
    }

    function adjustCommodityQuantity(uint256 commodityId, uint256 newRemainingQty) external {
    Commodity storage c = commodities[commodityId];
    require(c.id != 0, "commodity not found");

    require(msg.sender == c.seller || roles[msg.sender] == Role.Admin || msg.sender == superAdmin,
        "not authorized");

    require(newRemainingQty <= c.totalQuantity, "invalid quantity");

    c.remainingQuantity = newRemainingQty;

    if (newRemainingQty == 0) {
        c.status = CommodityStatus.SoldOut;
        emit CommodityStatusChanged(commodityId, CommodityStatus.SoldOut);
    }
    }


    // --- Trade recording ---
    /// @notice Record a trade (buyer or admin can call). No funds are handled on-chain by this function.
    /// Mints one NFT (ERC-721) representing the trade.
    function recordTrade(uint256 commodityId, address buyer, uint256 quantity, string calldata offchainReference) external {
        Commodity storage c = commodities[commodityId];
        require(c.id != 0, "commodity not found");
        require(c.status == CommodityStatus.Active, "commodity not active");
        require(quantity > 0 && quantity <= c.remainingQuantity, "invalid quantity");
        require(buyer != address(0), "buyer zero address");

        _tradeIdCounter++;
        uint256 tid = _tradeIdCounter;

        uint256 totalPrice = quantity * c.pricePerUnit;
        trades[tid] = TradeRecord({
            id: tid,
            commodityId: commodityId,
            buyer: buyer,
            seller: c.seller,
            quantity: quantity,
            pricePerUnit: c.pricePerUnit,
            totalPrice: totalPrice,
            timestamp: block.timestamp,
            offchainReference: offchainReference
        });

        commodityTrades[commodityId].push(tid);
        buyerTrades[buyer].push(tid);

        // reduce remaining quantity; if reaches 0, mark SoldOut
        c.remainingQuantity -= quantity;
        if (c.remainingQuantity == 0) {
            c.status = CommodityStatus.SoldOut;
            emit CommodityStatusChanged(commodityId, c.status);
        }

        emit TradeRecorded(tid, commodityId, buyer, quantity);

        // Mint NFT for this trade (use offchainReference as initial tokenURI if provided)
        _mintTradeNFT(tid, buyer, offchainReference);
    }

    function updateTradeOffchainReference(uint256 tradeId, string calldata ref) external onlyAdmin {
    TradeRecord storage t = trades[tradeId];
    require(t.id != 0, "trade not found");
    t.offchainReference = ref;
    }




    // --- View / helper functions ---
    function listSellerRequests(address sellerAddr) external view returns (uint256[] memory) {
        return sellerRequests[sellerAddr];
    }

    function listSellerCommodities(address sellerAddr) external view returns (uint256[] memory) {
        return sellerCommodities[sellerAddr];
    }

    function listCommodityTrades(uint256 commodityId) external view returns (uint256[] memory) {
        return commodityTrades[commodityId];
    }

    function listBuyerTrades(address buyerAddr) external view returns (uint256[] memory) {
        return buyerTrades[buyerAddr];
    }

    function changeSuperAdmin(address newSuperAdmin) external onlySuperAdmin {
        require(newSuperAdmin != address(0), "zero address");
        roles[superAdmin] = Role.None;
        emit RoleRevoked(superAdmin, Role.SuperAdmin);

        superAdmin = newSuperAdmin;
        roles[newSuperAdmin] = Role.SuperAdmin;
        emit RoleGranted(newSuperAdmin, Role.SuperAdmin);
    }

    function getListingRequest(uint256 requestId) external view returns (ListingRequest memory) {
        return listingRequests[requestId];
    }

    function getCommodity(uint256 commodityId) external view returns (Commodity memory) {
        return commodities[commodityId];
    }

    function getTrade(uint256 tradeId) external view returns (TradeRecord memory) {
        return trades[tradeId];
    }

    function getAllListingRequests() external view returns (ListingRequest[] memory) {
    ListingRequest[] memory arr = new ListingRequest[](_requestIdCounter);
    for(uint i = 1; i <= _requestIdCounter; i++) {
        arr[i-1] = listingRequests[i];
    }
    return arr;
    }

    function getAllCommodities() external view returns (Commodity[] memory) {
    Commodity[] memory arr = new Commodity[](_commodityIdCounter);
    for(uint i = 1; i <= _commodityIdCounter; i++) {
        arr[i-1] = commodities[i];
    }
    return arr;
    }

    function getAllTrades() external view returns (TradeRecord[] memory) {
    TradeRecord[] memory arr = new TradeRecord[](_tradeIdCounter);
    for(uint i = 1; i <= _tradeIdCounter; i++) {
        arr[i-1] = trades[i];
    }
    return arr;
    }

    // --- internal existence check using OZ _ownerOf (v5) ---
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    // --- internal tokenURI setter ---
    function _setTokenURI(uint256 tokenId, string memory uri) internal {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        _tokenURIs[tokenId] = uri;
    }

    // --- tokenURI override required by OZ v5 ---
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "Token does not exist");
        return _tokenURIs[tokenId];
    }

    // --- mint NFT for trade ---
    function _mintTradeNFT(uint256 tradeId, address to, string memory tokenURI_) internal {
        _tokenIdCounter.increment();
        uint256 tokenId = _tokenIdCounter.current();

        // _safeMint will call ERC721 internals that eventually call _update(...)
        _safeMint(to, tokenId);

        // set tokenURI if provided
        if (bytes(tokenURI_).length > 0) {
            _setTokenURI(tokenId, tokenURI_);
        } else {
            _setTokenURI(tokenId, "");
        }

        tokenTrade[tokenId] = tradeId;
        tokenStatus[tokenId] = NFTStatus.Active;
        tokenMintedAt[tokenId] = block.timestamp;

        emit NFTMinted(tokenId, tradeId, to);
    }

    // --- admin can update metadata ---
    function adminUpdateNFTMetadata(uint256 tokenId, string calldata newURI) external onlyAdmin {
        require(_exists(tokenId), "Token does not exist");
        string memory old = _tokenURIs[tokenId];
        _setTokenURI(tokenId, newURI);
        emit NFTMetadataUpdated(tokenId, old, newURI);
    }

    // --- admin can change NFT status ---
    function adminChangeNFTStatus(uint256 tokenId, NFTStatus newStatus) external onlyAdmin {
        require(_exists(tokenId), "Token does not exist");
        NFTStatus old = tokenStatus[tokenId];
        tokenStatus[tokenId] = newStatus;
        emit NFTStatusChanged(tokenId, old, newStatus);
    }

    // --- helper getters ---
    function getNFTDetails(uint256 tokenId) external view returns (
        uint256 tradeId,
        address owner,
        NFTStatus status,
        string memory uri,
        uint256 mintedAt
    ) {
        require(_exists(tokenId), "Token does not exist");
        tradeId = tokenTrade[tokenId];
        owner = ownerOf(tokenId);
        status = tokenStatus[tokenId];
        uri = tokenURI(tokenId);
        mintedAt = tokenMintedAt[tokenId];
    }

    function tokenOfTrade(uint256 tradeId) public view returns (uint256) {
        uint256 max = _tokenIdCounter.current();
        for (uint256 t = 1; t <= max; t++) {
            if (_exists(t) && tokenTrade[t] == tradeId) {
                return t;
            }
        }
        return 0;
    }

    function tokensOfOwner(address ownerAddr) external view returns (uint256[] memory) {
        uint256 balance = balanceOf(ownerAddr);
        uint256 max = _tokenIdCounter.current();
        uint256[] memory result = new uint256[](balance);
        uint256 counter = 0;
        for (uint256 t = 1; t <= max && counter < balance; t++) {
            if (_exists(t) && ownerOf(t) == ownerAddr) {
                result[counter] = t;
                counter++;
            }
        }
        return result;
    }

    // --- transfer restriction: only Admin or SuperAdmin can transfer NFTs ---
    function _isAdmin(address user) internal view returns (bool) {
        return roles[user] == Role.Admin || roles[user] == Role.SuperAdmin;
    }

    /// @dev Override OZ v5 hook `_update` to restrict transfers:
    /// - `auth == address(0)` => mint/burn (allowed)
    /// - otherwise `auth` is the caller performing the transfer; require admin.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (auth != address(0)) {
            // this is a transfer (not mint/burn) — require admin performing it
            require(_isAdmin(auth), "NFT transfer: admin only");
        }
        // fall back to OZ implementation
        return super._update(to, tokenId, auth);
    }

    // admin helper: allow admin to transfer token (calls safeTransferFrom which will route through _update)
    function adminTransferNFT(uint256 tokenId, address to) external onlyAdmin {
        address owner_ = ownerOf(tokenId);
        // this will eventually call _update(..., auth=msg.sender) so check will pass
        safeTransferFrom(owner_, to, tokenId);
    }

    // admin helper: burn token
    function adminBurnNFT(uint256 tokenId) external onlyAdmin {
        require(_exists(tokenId), "Token does not exist");
        _burn(tokenId);
    }

    // --- supportsInterface override (inherited from ERC721) ---
    function supportsInterface(bytes4 interfaceId) public view override(ERC721) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

