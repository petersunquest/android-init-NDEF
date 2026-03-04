// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../contracts/utils/cryptography/EIP712.sol";
import "../contracts/utils/cryptography/ECDSA.sol";
import "../b-unit/GuardianNodesInfoV6.sol";

// ------- PGP Public Key -------
struct PGPKey {
    string pgpKeyID;
    string publicKeyArmored;

    // ⚠️ MUST be ENCRYPTED private key (ciphertext). Never store plaintext private key on-chain.
    string encrypKeyArmored;

    bool exists;
}

contract AddressPGP is EIP712 {
    using ECDSA for bytes32;

    GuardianNodesInfoV6 public immutable guardianNodes;

    // --------------------------------------------------------------------
    // Admin
    // --------------------------------------------------------------------
    mapping(address => bool) public adminList;

    modifier requireAddressInAdminlist {
        require(adminList[msg.sender] == true, "not admin");
        _;
    }

    function changeAddressInAdminlist(address addr, bool status)
        external
        requireAddressInAdminlist
    {
        adminList[addr] = status;
    }

    constructor(address _guardianNodesInfoV6) EIP712("AddressPGP", "1") {
        require(_guardianNodesInfoV6 != address(0), "guardianNodes=0");
        guardianNodes = GuardianNodesInfoV6(_guardianNodesInfoV6);
        adminList[msg.sender] = true;
    }

    // --------------------------------------------------------------------
    // Nonces
    // --------------------------------------------------------------------
    mapping(address => uint256) public pgpNonces;
    mapping(address => uint256) public routerNonces;

    // --------------------------------------------------------------------
    // Storage (legacy / reserved)
    // --------------------------------------------------------------------
    mapping(address => string) public wallet2IP;
    mapping(string => address) public IP2Wallet;
    mapping(uint256 => address) public ID2Wallet;

    uint256[] public _nodeIds;
    mapping(uint256 => bool) public _nodeIdSeen;

    // --------------------------------------------------------------------
    // User PGP storage
    // --------------------------------------------------------------------
    mapping(address => PGPKey) public _pgpKeys;

    // ✅ 用户 pgpKeyIDHash -> 用户地址（用于通过 pgpKeyID 查用户）
    mapping(bytes32 => address) public pgpKeyIDHash2Wallet;

    // --------------------------------------------------------------------
    // ✅ Node route registry (admin managed)
    // Node PGP key/publicKey 从 GuardianNodesInfoV6 获取，此处仅存 keyHash 与 owner 绑定
    // --------------------------------------------------------------------
    mapping(bytes32 => bool) public nodeKeyExists;          // nodeKeyHash => 已登记为可用 route
    mapping(bytes32 => string) public nodeKeyIDByHash;      // nodeKeyHash => pgpKeyID string

    // node owner bindings (for setUserRouteToMe / setUserOnlineOnMe)
    mapping(address => bytes32) public nodeWallet2KeyHash;  // node owner => nodeKeyHash
    mapping(bytes32 => address) public nodeKeyHash2Wallet;  // nodeKeyHash => node owner

    // --------------------------------------------------------------------
    // ✅ Single Route: user => nodeKeyHash
    // --------------------------------------------------------------------
    mapping(address => bytes32) public userRouteHash; // 0 means unset

    // --------------------------------------------------------------------
    // ✅ Online status (single route)
    // - node can only update if userRouteHash[user] == nodeHash(msg.sender)
    // --------------------------------------------------------------------
    mapping(address => bool) public userOnlineOnRoute;  // overall online flag
    mapping(address => bytes32) public userOnlineNodeHash; // optional audit

    // --------------------------------------------------------------------
    // Events
    // --------------------------------------------------------------------
    event PGPKeySet(address indexed to, string pgpKeyID);

    event NodePublicKeyRecorded(bytes32 indexed pgpKeyIDHash, string pgpKeyID);
    event NodeWalletBound(bytes32 indexed pgpKeyIDHash, address indexed nodeWallet);
    event NodePublicKeyRemoved(bytes32 indexed pgpKeyIDHash, string pgpKeyID);

    event RouteSet(address indexed user, bytes32 indexed routeHash, string routePgpKeyID);
    event RouteCleared(address indexed user);

    event UserOnlineSet(address indexed user, bytes32 indexed nodeHash, bool online);

    // --------------------------------------------------------------------
    // EIP-712 typehashes
    // --------------------------------------------------------------------
    // User set PGP with optional route preset (route can be "")
    bytes32 private constant _ADD_PGP_TYPEHASH =
        keccak256(
            "AddPublicPGP(address to,bytes32 pgpKeyIDHash,bytes32 publicKeyArmoredHash,bytes32 encrypKeyArmoredHash,bytes32 routePgpKeyIDHash,uint256 nonce,uint256 deadline)"
        );

    // Relay set route for a user (single route)
    bytes32 private constant _SET_ROUTE_TYPEHASH =
        keccak256(
            "SetRoute(address to,bytes32 routePgpKeyIDHash,uint256 nonce,uint256 deadline)"
        );

    // --------------------------------------------------------------------
    // Admin: 登记 node 为可用 route，仅指定 IP，pgpKeyID/owner 从 GuardianNodesInfoV6 获取
    // --------------------------------------------------------------------
    function addRoute(string calldata ipaddress) external requireAddressInAdminlist {
        require(bytes(ipaddress).length != 0, "empty ip");
        require(guardianNodes.ipaddressExisting(ipaddress), "node not in GuardianNodesInfoV6");

        (, string memory pgpKey) = guardianNodes.IP2PGP(ipaddress);
        require(bytes(pgpKey).length != 0, "node has no pgpKey in GuardianNodesInfoV6");

        address owner = guardianNodes.ipaddress2owner(ipaddress);
        require(owner != address(0), "node has no owner");

        bytes32 h = keccak256(bytes(pgpKey));

        nodeKeyExists[h] = true;
        nodeKeyIDByHash[h] = pgpKey;

        nodeWallet2KeyHash[owner] = h;
        nodeKeyHash2Wallet[h] = owner;

        emit NodePublicKeyRecorded(h, pgpKey);
        emit NodeWalletBound(h, owner);
    }

    function addRoutes(string[] calldata ipaddresses) external requireAddressInAdminlist {
        require(ipaddresses.length > 0, "empty");

        for (uint256 i = 0; i < ipaddresses.length; i++) {
            string memory ip = ipaddresses[i];
            require(bytes(ip).length != 0, "empty ip");
            require(guardianNodes.ipaddressExisting(ip), "node not in GuardianNodesInfoV6");

            (, string memory pgpKey) = guardianNodes.IP2PGP(ip);
            require(bytes(pgpKey).length != 0, "node has no pgpKey in GuardianNodesInfoV6");

            address owner = guardianNodes.ipaddress2owner(ip);
            require(owner != address(0), "node has no owner");

            bytes32 h = keccak256(bytes(pgpKey));

            nodeKeyExists[h] = true;
            nodeKeyIDByHash[h] = pgpKey;

            nodeWallet2KeyHash[owner] = h;
            nodeKeyHash2Wallet[h] = owner;

            emit NodePublicKeyRecorded(h, pgpKey);
            emit NodeWalletBound(h, owner);
        }
    }

    // admin delete/disable node from route registry (does not remove from GuardianNodesInfoV6)
    function removeRoute(string calldata pgpKeyID)
        external
        requireAddressInAdminlist
    {
        require(bytes(pgpKeyID).length != 0, "empty keyID");

        bytes32 h = keccak256(bytes(pgpKeyID));
        require(nodeKeyExists[h], "not recorded");

        nodeKeyExists[h] = false;
        nodeKeyIDByHash[h] = "";

        address w = nodeKeyHash2Wallet[h];
        if (w != address(0)) {
            nodeWallet2KeyHash[w] = bytes32(0);
            nodeKeyHash2Wallet[h] = address(0);
        }

        emit NodePublicKeyRemoved(h, pgpKeyID);
    }

    // --------------------------------------------------------------------
    // Internal helpers
    // --------------------------------------------------------------------
    function _requireNodeHashExists(bytes32 routeHash) internal view {
        require(nodeKeyExists[routeHash], "route key not recorded");
    }

    /// @dev 校验 routePgpKeyID 在 GuardianNodesInfoV6 中存在
    function _requireRouteExistsInGuardianNodes(string calldata routePgpKeyID) internal view {
        if (bytes(routePgpKeyID).length == 0) return;
        require(
            bytes(guardianNodes.getPGPKeyIPaddress(routePgpKeyID)).length != 0,
            "routePgpKeyID not in GuardianNodesInfoV6"
        );
    }

    /// @dev 校验 routeKeyID 在 GuardianNodesInfoV6 中存在（用于读路径的 route 有效性）
    function _isRouteValidInGuardianNodes(string memory routeKeyID) internal view returns (bool) {
        if (bytes(routeKeyID).length == 0) return false;
        return bytes(guardianNodes.getPGPKeyIPaddress(routeKeyID)).length != 0;
    }

    function _routeHashFromKeyID(string calldata routePgpKeyID) internal pure returns (bytes32) {
        if (bytes(routePgpKeyID).length == 0) return bytes32(0);
        return keccak256(bytes(routePgpKeyID));
    }

    /// @dev 设置用户 route。routePgpKeyID 已通过 _requireRouteExistsInGuardianNodes 校验时，
    ///      无需 nodeKeyExists 本地登记，直接使用 GuardianNodesInfoV6 作为路由来源。
    function _setUserRouteHash(address user, bytes32 routeHash, string memory routeKeyIDForEvent) internal {
        if (routeHash != bytes32(0) && bytes(routeKeyIDForEvent).length != 0) {
            nodeKeyIDByHash[routeHash] = routeKeyIDForEvent;
        }

        userRouteHash[user] = routeHash;

        // route changed => clear online (avoid stale state)
        userOnlineOnRoute[user] = false;
        userOnlineNodeHash[user] = bytes32(0);

        emit RouteSet(user, routeHash, routeKeyIDForEvent);
    }

    // --------------------------------------------------------------------
    // EIP-712 helpers
    // --------------------------------------------------------------------
    function _buildAddPgpStructHash(
        address to,
        bytes32 pgpKeyIDHash,
        bytes32 publicKeyArmoredHash,
        bytes32 encrypKeyArmoredHash,
        bytes32 routePgpKeyIDHash,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _ADD_PGP_TYPEHASH,
                to,
                pgpKeyIDHash,
                publicKeyArmoredHash,
                encrypKeyArmoredHash,
                routePgpKeyIDHash,
                nonce,
                deadline
            )
        );
    }

    function _buildSetRouteStructHash(
        address to,
        bytes32 routePgpKeyIDHash,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _SET_ROUTE_TYPEHASH,
                to,
                routePgpKeyIDHash,
                nonce,
                deadline
            )
        );
    }

    // --------------------------------------------------------------------
    // User: set PGP (direct + bySig)
    // - routePgpKeyID can be "" to skip setting route here
    // --------------------------------------------------------------------
    function _setPGPOnly(
        address to,
        string calldata pgpKeyID,
        string calldata publicKeyArmored,
        string calldata encrypKeyArmored
    ) internal {
        _pgpKeys[to] = PGPKey({
            pgpKeyID: pgpKeyID,
            publicKeyArmored: publicKeyArmored,
            encrypKeyArmored: encrypKeyArmored,
            exists: true
        });

        // pgpKeyID -> wallet index (for lookup)
        pgpKeyIDHash2Wallet[keccak256(bytes(pgpKeyID))] = to;

        emit PGPKeySet(to, pgpKeyID);
    }

    function addPublicPGP(
        address to,
        string calldata pgpKeyID,
        string calldata publicKeyArmored,
        string calldata encrypKeyArmored,
        string calldata routePgpKeyID // optional
    ) external {
        require(to == msg.sender, "only owner");

        // 校验 routePgpKeyID 在 GuardianNodesInfoV6 中存在
        _requireRouteExistsInGuardianNodes(routePgpKeyID);

        _setPGPOnly(to, pgpKeyID, publicKeyArmored, encrypKeyArmored);

        if (bytes(routePgpKeyID).length != 0) {
            bytes32 rh = keccak256(bytes(routePgpKeyID));
            _setUserRouteHash(to, rh, routePgpKeyID);
        }
    }

    /// @dev Admin 为用户登记 PGP（用户登录/注册场景，服务端代用户上链）
    function addPublicPGPByAdmin(
        address to,
        string calldata pgpKeyID,
        string calldata publicKeyArmored,
        string calldata encrypKeyArmored,
        string calldata routePgpKeyID // optional
    ) external requireAddressInAdminlist {
        require(to != address(0), "to=0");

        // 校验 routePgpKeyID 在 GuardianNodesInfoV6 中存在
        _requireRouteExistsInGuardianNodes(routePgpKeyID);

        _setPGPOnly(to, pgpKeyID, publicKeyArmored, encrypKeyArmored);

        if (bytes(routePgpKeyID).length != 0) {
            bytes32 rh = keccak256(bytes(routePgpKeyID));
            _setUserRouteHash(to, rh, routePgpKeyID);
        }
    }

    function _verifyPGPSignatureHashed(
        address to,
        bytes32 pgpKeyIDHash,
        bytes32 publicKeyArmoredHash,
        bytes32 encrypKeyArmoredHash,
        bytes32 routePgpKeyIDHash, // may be 0 if no route preset
        uint256 deadline,
        bytes calldata signature
    ) internal {
        require(to != address(0), "to=0");
        require(block.timestamp <= deadline, "sig expired");

        uint256 nonce = pgpNonces[to]++;

        bytes32 structHash = _buildAddPgpStructHash(
            to,
            pgpKeyIDHash,
            publicKeyArmoredHash,
            encrypKeyArmoredHash,
            routePgpKeyIDHash,
            nonce,
            deadline
        );

        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == to, "bad sig");
    }

    function addPublicPGPBySig(
        address to,
        string calldata pgpKeyID,
        string calldata publicKeyArmored,
        string calldata encrypKeyArmored,
        string calldata routePgpKeyID, // optional
        uint256 deadline,
        bytes calldata signature
    ) external {
        // 校验 routePgpKeyID 在 GuardianNodesInfoV6 中存在（无需 AddressPGP 本地 addRoutes）
        _requireRouteExistsInGuardianNodes(routePgpKeyID);

        bytes32 routeHash = _routeHashFromKeyID(routePgpKeyID);

        _verifyPGPSignatureHashed(
            to,
            keccak256(bytes(pgpKeyID)),
            keccak256(bytes(publicKeyArmored)),
            keccak256(bytes(encrypKeyArmored)),
            routeHash,
            deadline,
            signature
        );

        _setPGPOnly(to, pgpKeyID, publicKeyArmored, encrypKeyArmored);

        if (routeHash != bytes32(0)) {
            _setUserRouteHash(to, routeHash, routePgpKeyID);
        }
    }

    // --------------------------------------------------------------------
    // User: manage route (single)
    // --------------------------------------------------------------------
    function setMyRoute(string calldata routePgpKeyID) external {
        require(bytes(routePgpKeyID).length != 0, "empty route keyID");
        _requireRouteExistsInGuardianNodes(routePgpKeyID);
        bytes32 rh = keccak256(bytes(routePgpKeyID));
        _setUserRouteHash(msg.sender, rh, routePgpKeyID);
    }

    function clearMyRoute() external {
        userRouteHash[msg.sender] = bytes32(0);
        userOnlineOnRoute[msg.sender] = false;
        userOnlineNodeHash[msg.sender] = bytes32(0);
        emit RouteCleared(msg.sender);
    }

    // --------------------------------------------------------------------
    // Relay: set route for user by signature (single route)
    // --------------------------------------------------------------------
    function _verifySetRouteSig(
        address to,
        bytes32 routePgpKeyIDHash,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        require(to != address(0), "to=0");
        require(block.timestamp <= deadline, "sig expired");
        require(routePgpKeyIDHash != bytes32(0), "empty route hash");

        uint256 nonce = routerNonces[to]++;

        bytes32 structHash = _buildSetRouteStructHash(
            to,
            routePgpKeyIDHash,
            nonce,
            deadline
        );

        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        require(signer == to, "bad sig");
    }

    function setRouteBySig(
        address to,
        string calldata routePgpKeyID,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(bytes(routePgpKeyID).length != 0, "empty route keyID");
        _requireRouteExistsInGuardianNodes(routePgpKeyID);
        bytes32 rh = keccak256(bytes(routePgpKeyID));

        _verifySetRouteSig(to, rh, deadline, signature);

        _setUserRouteHash(to, rh, routePgpKeyID);
    }

    // --------------------------------------------------------------------
    // Node wallet: set user route = self (overwrite)
    // --------------------------------------------------------------------
    function setUserRouteToMe(address user) external {
        require(user != address(0), "user=0");

        string[] memory ips = guardianNodes.getOwnerIPs(msg.sender);
        require(ips.length > 0, "caller not node");
        (, string memory keyID) = guardianNodes.IP2PGP(ips[0]);
        require(bytes(keyID).length != 0, "node has no pgpKey in GuardianNodesInfoV6");

        bytes32 myHash = keccak256(bytes(keyID));
        _setUserRouteHash(user, myHash, keyID);
    }

    // --------------------------------------------------------------------
    // ✅ Online status (single route)
    // --------------------------------------------------------------------
    function isOnline(address user) external view returns (bool) {
        return userOnlineOnRoute[user];
    }

    // node sets: user connected on this node or not
    // - caller must be a registered node wallet
    // - user must be routed to caller's node
    function setUserOnlineOnMe(address user, bool online) external {
        require(user != address(0), "user=0");

        string[] memory ips = guardianNodes.getOwnerIPs(msg.sender);
        require(ips.length > 0, "caller not node");
        (, string memory keyID) = guardianNodes.IP2PGP(ips[0]);
        require(bytes(keyID).length != 0, "node has no pgpKey in GuardianNodesInfoV6");

        bytes32 myHash = keccak256(bytes(keyID));
        require(userRouteHash[user] == myHash, "user not routed to me");

        userOnlineOnRoute[user] = online;
        userOnlineNodeHash[user] = online ? myHash : bytes32(0);

        emit UserOnlineSet(user, myHash, online);
    }

    // --------------------------------------------------------------------
    // Reads
    // --------------------------------------------------------------------

    // ✅ address -> user key + route keyID + route pubkey (from GuardianNodesInfoV6) + online
    function searchKey(address to)
        external
        view
        returns (
            string memory userPgpKeyID,
            string memory userPublicKeyArmored,
            string memory routePgpKeyID,
            string memory routePublicKeyArmored,
            bool routeOnline
        )
    {
        PGPKey storage k = _pgpKeys[to];
        if (!k.exists) {
            return ("", "", "", "", false);
        }

        bytes32 rh = userRouteHash[to];
        string memory rKeyID = nodeKeyIDByHash[rh];
        if (rh == bytes32(0) || bytes(rKeyID).length == 0 || !_isRouteValidInGuardianNodes(rKeyID)) {
            return (k.pgpKeyID, k.publicKeyArmored, "", "", false);
        }
        // route 的 PGP public key 从 GuardianNodesInfoV6 获取
        string memory rPubkey = guardianNodes.pgpKeyToPGP(rKeyID);

        return (
            k.pgpKeyID,
            k.publicKeyArmored,
            rKeyID,
            rPubkey,
            userOnlineOnRoute[to]
        );
    }

    function getEncryptedPrivateKey() external view returns (string memory) {
        PGPKey storage k = _pgpKeys[msg.sender];
        if (!k.exists) return "";
        return k.encrypKeyArmored;
    }

    // ✅ user PGP keyID -> user address
    function getUserByPgpKeyID(string calldata userPgpKeyID)
        external
        view
        returns (address)
    {
        return pgpKeyIDHash2Wallet[keccak256(bytes(userPgpKeyID))];
    }

    // ✅ user PGP keyID -> route keyID (你要的：以 PGP key 查 route keyID)
    function getRouteKeyIDByUserPgpKeyID(string calldata userPgpKeyID)
        external
        view
        returns (string memory routePgpKeyID)
    {
        address user = pgpKeyIDHash2Wallet[keccak256(bytes(userPgpKeyID))];
        require(user != address(0), "user not found");

        bytes32 rh = userRouteHash[user];
        string memory rKeyID = nodeKeyIDByHash[rh];
        if (rh == bytes32(0) || bytes(rKeyID).length == 0 || !_isRouteValidInGuardianNodes(rKeyID)) return "";

        return rKeyID;
    }

    // ✅ address -> route keyID
    function getRouteKeyIDByAddress(address user)
        external
        view
        returns (string memory routePgpKeyID)
    {
        bytes32 rh = userRouteHash[user];
        string memory rKeyID = nodeKeyIDByHash[rh];
        if (rh == bytes32(0) || bytes(rKeyID).length == 0 || !_isRouteValidInGuardianNodes(rKeyID)) return "";
        return rKeyID;
    }
}
