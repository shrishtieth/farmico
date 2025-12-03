
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Minimal interface for RolesManager
interface IRoles {
    function hasRole(address account, uint8 role) external view returns (bool);
}

/// @dev Minimal interface for TradeNFT (only signatures used here)
interface ITradeNFT {
    function mintNFT(uint256 tradeId, address to, string calldata uri) external returns (uint256);
    function adminChangeNFTStatus(uint256 tokenId, uint8 newStatus) external;
    function adminUpdateNFTMetadata(uint256 tokenId, string calldata newURI) external;
}

contract Marketplace {
    IRoles public rolesContract;
    ITradeNFT public nftContract;

    constructor(address rolesAddr, address nftAddr) {
        require(rolesAddr != address(0) && nftAddr != address(0), "zero addr");
        rolesContract = IRoles(rolesAddr);
        nftContract = ITradeNFT(nftAddr);
    }

    // --- Counters ---
    uint256 private _requestIdCounter;
    uint256 private _commodityIdCounter;
    uint256 private _tradeIdCounter;

    // --- Enums & Structs ---
    enum RequestStatus { Pending, Approved, Rejected, Cancelled }
    enum CommodityStatus { Inactive, Active, SoldOut, Removed }

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

    // --- Storage ---
    mapping(uint256 => ListingRequest) public listingRequests;
    mapping(address => uint256[]) public sellerRequests;

    mapping(uint256 => Commodity) public commodities;
    mapping(address => uint256[]) public sellerCommodities;

    mapping(uint256 => TradeRecord) public trades;
    mapping(uint256 => uint256[]) public commodityTrades;
    mapping(address => uint256[]) public buyerTrades;

    // --- Events ---
    event ListingRequested(uint256 indexed requestId, address indexed seller);
    event ListingApproved(uint256 indexed requestId, uint256 indexed commodityId);
    event ListingRejected(uint256 indexed requestId, string reason);
    event ListingCancelled(uint256 indexed requestId);

    event CommodityStageUpdated(uint256 indexed commodityId, string stage, string location, string misc);
    event CommodityStatusChanged(uint256 indexed commodityId, CommodityStatus status);

    event TradeRecorded(uint256 indexed tradeId, uint256 indexed commodityId, address indexed buyer, uint256 quantity);

    // --- Modifiers ---
    modifier onlySeller() {
        require(rolesContract.hasRole(msg.sender, 2), "Only seller");
        _;
    }
    modifier onlyAdmin() {
        // Admin = 3, SuperAdmin = 4
        require(rolesContract.hasRole(msg.sender, 3) || rolesContract.hasRole(msg.sender, 4), "Only admin/superAdmin");
        _;
    }
    modifier onlyBuyer() {
        // Buyer=1, Seller=2 (also allowed), Admin=3, SuperAdmin=4
        require(
            rolesContract.hasRole(msg.sender, 1) ||
            rolesContract.hasRole(msg.sender, 2) ||
            rolesContract.hasRole(msg.sender, 3) ||
            rolesContract.hasRole(msg.sender, 4),
            "Only buyer role"
        );
        _;
    }

    // -------------------------
    // Listing request functions
    // -------------------------
    function requestListing(
        string calldata title,
        string calldata description,
        string calldata category,
        uint256 quantity,
        uint256 pricePerUnit
    ) external onlySeller returns (uint256) {
        require(quantity > 0, "quantity>0");
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

    function cancelListingRequest(uint256 requestId) external onlySeller {
        ListingRequest storage r = listingRequests[requestId];
        require(r.id != 0, "request not found");
        require(r.seller == msg.sender, "not owner");
        require(r.status == RequestStatus.Pending, "not pending");
        r.status = RequestStatus.Cancelled;
        emit ListingCancelled(requestId);
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
        require(r.seller == msg.sender, "not owner");
        require(r.status == RequestStatus.Pending, "not editable");

        r.title = title;
        r.description = description;
        r.category = category;
        r.quantity = quantity;
        r.pricePerUnit = pricePerUnit;
    }

    function rejectListingRequest(uint256 requestId, string calldata reason) external onlyAdmin {
        ListingRequest storage r = listingRequests[requestId];
        require(r.id != 0, "request not found");
        require(r.status == RequestStatus.Pending, "not pending");
        r.status = RequestStatus.Rejected;
        r.adminNotes = reason;
        emit ListingRejected(requestId, reason);
    }

    function approveListingRequest(uint256 requestId, string calldata adminNote) external onlyAdmin returns (uint256) {
        ListingRequest storage r = listingRequests[requestId];
        require(r.id != 0, "request not found");
        require(r.status == RequestStatus.Pending, "not pending");
        r.status = RequestStatus.Approved;
        r.adminNotes = adminNote;

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

    // -------------------------
    // Commodity functions (combined & helpers)
    // -------------------------
    function updateCommodityStage(
        uint256 commodityId,
        string calldata stage,
        string calldata location,
        string calldata misc
    ) external {
        Commodity storage c = commodities[commodityId];
        require(c.id != 0, "commodity not found");
        require(c.status == CommodityStatus.Active, "commodity not active");
        // seller or admin
        require(msg.sender == c.seller || rolesContract.hasRole(msg.sender, 3) || rolesContract.hasRole(msg.sender, 4),
            "not authorized");

        c.currentStage = stage;
        c.location = location;
        c.misc = misc;
        emit CommodityStageUpdated(commodityId, stage, location, misc);
    }

    /// @notice Combined update details + adjust remaining quantity if needed.
    function updateCommodityDetailsAndQuantity(
        uint256 commodityId,
        string calldata title,
        string calldata category,
        uint256 pricePerUnit,
        uint256 newRemainingQty
    ) external {
        Commodity storage c = commodities[commodityId];
        require(c.id != 0, "commodity not found");
        require(msg.sender == c.seller || rolesContract.hasRole(msg.sender, 3) || rolesContract.hasRole(msg.sender, 4),
            "not authorized");

        c.title = title;
        c.category = category;
        c.pricePerUnit = pricePerUnit;

        require(newRemainingQty <= c.totalQuantity, "invalid remaining");
        c.remainingQuantity = newRemainingQty;
        if (c.remainingQuantity == 0) {
            c.status = CommodityStatus.SoldOut;
            emit CommodityStatusChanged(commodityId, c.status);
        }
    }

    function changeCommodityStatus(uint256 commodityId, CommodityStatus newStatus) external {
        Commodity storage c = commodities[commodityId];
        require(c.id != 0, "commodity not found");
        require(msg.sender == c.seller || rolesContract.hasRole(msg.sender, 3) || rolesContract.hasRole(msg.sender, 4),
            "not authorized");
        c.status = newStatus;
        emit CommodityStatusChanged(commodityId, newStatus);
    }

    // -------------------------
    // Trade functions
    // -------------------------
    function recordTrade(
        uint256 commodityId,
        address buyer,
        uint256 quantity,
        string calldata offchainReference
    ) external onlyBuyer returns (uint256) {
        Commodity storage c = commodities[commodityId];
        require(c.id != 0, "commodity not found");
        require(c.status == CommodityStatus.Active, "commodity not active");
        require(quantity > 0 && quantity <= c.remainingQuantity, "invalid quantity");
        require(buyer != address(0), "buyer zero");

        _tradeIdCounter++;
        uint256 tid = _tradeIdCounter;

        trades[tid] = TradeRecord({
            id: tid,
            commodityId: commodityId,
            buyer: buyer,
            seller: c.seller,
            quantity: quantity,
            pricePerUnit: c.pricePerUnit,
            totalPrice: quantity * c.pricePerUnit,
            timestamp: block.timestamp,
            offchainReference: offchainReference
        });

        commodityTrades[commodityId].push(tid);
        buyerTrades[buyer].push(tid);

        c.remainingQuantity -= quantity;
        if (c.remainingQuantity == 0) {
            c.status = CommodityStatus.SoldOut;
            emit CommodityStatusChanged(commodityId, c.status);
        }

        emit TradeRecorded(tid, commodityId, buyer, quantity);

        // Mint NFT via interface; Marketplace must be authorized in NFT (see TradeNFT.setMarketplace)
        nftContract.mintNFT(tid, buyer, offchainReference);
        return tid;
    }

    function updateTradeOffchainReference(uint256 tradeId, string calldata ref) external onlyAdmin {
        TradeRecord storage tr = trades[tradeId];
        require(tr.id != 0, "trade not found");
        tr.offchainReference = ref;
    }

    // -------------------------
    // Read / helper functions
    // -------------------------
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
        for (uint256 i = 1; i <= _requestIdCounter; i++) arr[i - 1] = listingRequests[i];
        return arr;
    }

    function getAllCommodities() external view returns (Commodity[] memory) {
        Commodity[] memory arr = new Commodity[](_commodityIdCounter);
        for (uint256 i = 1; i <= _commodityIdCounter; i++) arr[i - 1] = commodities[i];
        return arr;
    }

    function getAllTrades() external view returns (TradeRecord[] memory) {
        TradeRecord[] memory arr = new TradeRecord[](_tradeIdCounter);
        for (uint256 i = 1; i <= _tradeIdCounter; i++) arr[i - 1] = trades[i];
        return arr;
    }

    // -------------------------
    // Admin helpers: update external contract addresses (in case of upgrades)
    // -------------------------
    function setNFTContract(address nftAddr) external {
        require(rolesContract.hasRole(msg.sender, 4), "only superAdmin"); // only superAdmin
        require(nftAddr != address(0), "zero addr");
        nftContract = ITradeNFT(nftAddr);
    }

    function setRolesContract(address rolesAddr) external {
        require(rolesContract.hasRole(msg.sender, 4), "only superAdmin"); // only superAdmin
        require(rolesAddr != address(0), "zero addr");
        rolesContract = IRoles(rolesAddr);
    }
}
