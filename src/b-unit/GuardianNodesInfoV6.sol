// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* -----------------------------------------
 * Ordered, iterable, deduplicated set for string
 * - Keeps insertion order
 * - remove() keeps order (left-shift), O(n)
 * ----------------------------------------- */
library OrderedStringSet {
    struct Set {
        string[] _values;
        mapping(string => uint256) _index; // 1-based index; 0 means not present
    }

    function contains(Set storage set, string memory value) internal view returns (bool) {
        return set._index[value] != 0;
    }

    function length(Set storage set) internal view returns (uint256) {
        return set._values.length;
    }

    function at(Set storage set, uint256 i) internal view returns (string memory) {
        require(i < set._values.length, "index out of bounds");
        return set._values[i];
    }

    function add(Set storage set, string memory value) internal returns (bool) {
        if (contains(set, value)) return false;
        set._values.push(value);
        set._index[value] = set._values.length; // 1-based
        return true;
    }

    // keep-order removal (shift-left). Gas O(n), but preserves insertion order.
    function remove(Set storage set, string memory value) internal returns (bool) {
        uint256 idx = set._index[value];
        if (idx == 0) return false; // not exists

        uint256 i = idx - 1; // to 0-based
        uint256 last = set._values.length - 1;

        // shift-left from i .. last-1
        for (uint256 j = i; j < last; j++) {
            string memory nextVal = set._values[j + 1];
            set._values[j] = nextVal;
            set._index[nextVal] = j + 1; // store 1-based
        }

        set._values.pop();
        delete set._index[value];
        return true;
    }

    // Return a copy of all values (in order)
    function values(Set storage set) internal view returns (string[] memory out) {
        uint256 n = set._values.length;
        out = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = set._values[i];
        }
    }
}

/* ----------------------------------------- */

struct nodeInfo {
    uint256 id;
    string PGP;
    string PGPKey;
    string ip_addr;
    string regionName;
}

contract GuardianNodesInfoV6 {
    using OrderedStringSet for OrderedStringSet.Set;

    mapping (address => bool ) public adminList;

    constructor() {
        adminList[msg.sender] = true;
    }

    function hashString (string memory text) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(text));
    }

    modifier requireAddressInAdminlist {
        require(adminList[msg.sender] == true, "not admin");
        _;
    }

    // ===================== 工具函数（仅内部） =====================

    // 比较字符串是否相等
    function _strEq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    // 从 regionList 中移除空区域（当该区域没有节点时调用）
    function _removeRegionIfEmpty(string memory regionName) internal {
        if (_regionNodes[regionName].length() == 0 && regionExisting[regionName]) {
            // 在 regionList 里做顺序删除（保持顺序，左移）
            _orderedRemoveRegion(regionName);
            delete regionExisting[regionName];
        }
    }

    // 将 owner 加入 _ownerList（若尚未存在）
    function _addOwnerToList(address owner) internal {
        if (_ownerIndex[owner] != 0) return;
        _ownerList.push(owner);
        _ownerIndex[owner] = _ownerList.length; // 1-based
    }

    // 从 _ownerList 移除 owner（当其不再拥有任何节点时）
    function _removeOwnerFromList(address owner) internal {
        uint256 idx = _ownerIndex[owner];
        if (idx == 0) return;
        uint256 lastIdx = _ownerList.length;
        if (idx != lastIdx) {
            address lastOwner = _ownerList[lastIdx - 1];
            _ownerList[idx - 1] = lastOwner;
            _ownerIndex[lastOwner] = idx;
        }
        _ownerList.pop();
        delete _ownerIndex[owner];
    }

    // 顺序删除 regionList 内的某个 region（保持顺序，左移）
    function _orderedRemoveRegion(string memory regionName) internal {
        uint256 len = regionList.length;
        for (uint256 i = 0; i < len; i++) {
            if (_strEq(regionList[i], regionName)) {
                for (uint256 j = i; j + 1 < len; j++) {
                    regionList[j] = regionList[j + 1];
                }
                regionList.pop();
                break;
            }
        }
    }

    // ===================== 存储区 =====================

    event deleteIPAddr (bytes32 indexed ipAddr, bytes32 indexed regin);

    // 区域列表仍用数组 + 去重标记：保持插入顺序
    string[] public regionList;
    mapping (string => bool) public regionExisting;

    // region_nodes -> 有序去重集合
    mapping (string => OrderedStringSet.Set) private _regionNodes;

    // ownerIPs -> 有序去重集合
    mapping (address => OrderedStringSet.Set) private _ownerIPs;

    // 唯一 owner 列表（用于 getUniqueOwnerCount，ConetTreasury 的 requiredVotes 依赖）
    address[] private _ownerList;
    mapping (address => uint256) private _ownerIndex; // 1-based, 0 = not in list

    // ip -> region
    mapping (string => string)  public ipaddressToRegion;
    // ip 是否存在
    mapping (string => bool)    public ipaddressExisting;

    // PGP 相关映射
    mapping (string => string)  public ipaddress2PGP;
    mapping (string => string)  public ipaddress2pgpKey;
    mapping (string => string)  public pgpKey2ipaddress;
    mapping (string => string)  public pgpKeyToPGP;

    // ID/Owner 侧
    mapping (uint256 => address) public idOwner;
    mapping (string => address)   public ipaddress2owner; // IP -> Owner

    // 全量 IP 集合（用于分页，保持顺序 & 去重）
    OrderedStringSet.Set private _ipSet;

    // 双向：IP <-> ID
    mapping (string => uint256) public ip2id;
    mapping (uint256 => string) public id2ip;

    // ===================== 业务函数 =====================

    function regionNodeUpdate(string memory regionName, string memory ipaddress) internal {
        ipaddressToRegion[ipaddress] = regionName;

        if (!ipaddressExisting[ipaddress]) {
            ipaddressExisting[ipaddress] = true;

            // 进全量 IP 集合
            _ipSet.add(ipaddress);
        }

        // 区域的集合去重插入
        _regionNodes[regionName].add(ipaddress);

        if (!regionExisting[regionName]) {
            regionList.push(regionName);
            regionExisting[regionName] = true;
        }
    }

    function getAllRegions () public view returns (string[] memory Regions) {
        Regions = regionList;
    }

    // 有序列出某区域内所有 IP
    function getRegionNodes(string memory regionName) public view returns (string[] memory nodes) {
        nodes = _regionNodes[regionName].values();
    }

    // 有序列出某 Owner 的所有 IP
    function getOwnerIPs(address owner) public view returns (string[] memory ips) {
        ips = _ownerIPs[owner].values();
    }

    /// @dev 唯一 owner 数量（ConetTreasury.requiredVotes 依赖此值）
    function getUniqueOwnerCount() public view returns (uint256) {
        return _ownerList.length;
    }

    function IP2PGP (string memory ipaddress) public view returns (string memory pgp, string memory pgpKey) {
        pgp = ipaddress2PGP[ipaddress];
        pgpKey = ipaddress2pgpKey[ipaddress];
    }

    function getPGPKeyIPaddress (string memory pgpKey) public view returns (string memory ipaddress) {
        ipaddress = pgpKey2ipaddress[pgpKey];
    }

    function pgpUpdate (string memory pgp, string memory pgpKey, string memory ipaddress)
        public
        requireAddressInAdminlist
    {
        ipaddress2pgpKey[ipaddress] = pgpKey;
        ipaddress2PGP[ipaddress]    = pgp;
        pgpKey2ipaddress[pgpKey]    = ipaddress;
        pgpKeyToPGP[pgpKey]         = pgp;
    }

    // 绑定 id、nodeAddress、ip 的维护：去重且保持顺序；同时记录 ip<->id。一个 node 唯一对应 id、ipaddress、pgp、pgpKey
    function id2node (address nodeAddress, uint256 id, string memory ipaddress)
        public
        requireAddressInAdminlist
    {
        idOwner[id] = nodeAddress;

        // 如果 IP 已有 nodeAddress，且不同，则从旧地址的集合里移除
        address oldAddr = ipaddress2owner[ipaddress];
        if (oldAddr != address(0) && oldAddr != nodeAddress) {
            _ownerIPs[oldAddr].remove(ipaddress);
            if (_ownerIPs[oldAddr].length() == 0) _removeOwnerFromList(oldAddr);
        }

        // 记录新 nodeAddress，并去重插入
        ipaddress2owner[ipaddress] = nodeAddress;
        _ownerIPs[nodeAddress].add(ipaddress);
        _addOwnerToList(nodeAddress);

        // 维护 IP <-> ID
        ip2id[ipaddress] = id;
        id2ip[id]        = ipaddress;
    }

    function removeNode (string memory ipaddress)
        public
        requireAddressInAdminlist
    {
        require(ipaddressExisting[ipaddress], "Node not exists");

        // 1) 从所属区域集合里删除
        string memory regionName = ipaddressToRegion[ipaddress];
        if (bytes(regionName).length != 0) {
            _regionNodes[regionName].remove(ipaddress);
            _removeRegionIfEmpty(regionName);
        }

        // 2) 从 owner 的集合中删除并清理索引
        address owner = ipaddress2owner[ipaddress];
        if (owner != address(0)) {
            _ownerIPs[owner].remove(ipaddress);
            if (_ownerIPs[owner].length() == 0) _removeOwnerFromList(owner);
            delete ipaddress2owner[ipaddress];
        }

        // 3) 清理 PGP 相关映射
        string memory pgpKey = ipaddress2pgpKey[ipaddress];
        if (bytes(pgpKey).length != 0) {
            delete pgpKey2ipaddress[pgpKey];
            delete pgpKeyToPGP[pgpKey];
        }
        delete ipaddress2pgpKey[ipaddress];
        delete ipaddress2PGP[ipaddress];

        // 4) 清理 IP 与 ID 绑定
        uint256 nid = ip2id[ipaddress];
        if (nid != 0 || bytes(id2ip[nid]).length != 0) {
            delete id2ip[nid];
            delete ip2id[ipaddress];
        }

        // 5) 从全量 IP 集合移除
        _ipSet.remove(ipaddress);

        // 6) 清理 IP 标记与归属
        delete ipaddressExisting[ipaddress];
        delete ipaddressToRegion[ipaddress];

        emit deleteIPAddr(hashString(ipaddress), hashString(regionName));
    }

    function addNode (
        uint256 id,
        string memory ipaddress,
        string memory regionName,
        string memory pgp,
        string memory pgpKey,
        address nodeAddress
    )
        public
        requireAddressInAdminlist
    {
        regionNodeUpdate(regionName, ipaddress);
        pgpUpdate(pgp, pgpKey, ipaddress);
        id2node(nodeAddress, id, ipaddress);
    }

    // 兼容旧命名（你原函数名有个小拼写）
    function getReginNodes (string memory regionName) public view returns (string[] memory nodes) {
        nodes = getRegionNodes(regionName);
    }

    function changeAddressInAdminlist (address addr, bool status) public requireAddressInAdminlist {
        adminList[addr] = status;
    }

    /// @dev 迁移：从现有节点填充 _ownerList（升级后首次调用，仅当 _ownerList 为空时有效）
    function migrateOwnerList() external requireAddressInAdminlist {
        require(_ownerList.length == 0, "already migrated");
        uint256 total = _ipSet.length();
        for (uint256 i = 0; i < total; i++) {
            string memory ip = _ipSet.at(i);
            address owner = ipaddress2owner[ip];
            if (owner != address(0)) _addOwnerToList(owner);
        }
    }

    // 分页获取节点（按全量 IP 集合的插入顺序）
    function getAllNodes(uint256 start, uint256 length)
        public
        view
        returns (nodeInfo[] memory allNodes)
    {
        uint256 total = _ipSet.length();
        if (start >= total) {
            return new nodeInfo[](0);
        }
        uint256 end = start + length;
        if (end > total) end = total;
        uint256 n = end - start;

        allNodes = new nodeInfo[](n);
        for (uint256 i = 0; i < n; i++) {
            string memory ip = _ipSet.at(start + i);
            allNodes[i] = nodeInfo({
                id: ip2id[ip],
                PGP: ipaddress2PGP[ip],
                PGPKey: ipaddress2pgpKey[ip],
                ip_addr: ip,
                regionName: ipaddressToRegion[ip]
            });
        }
    }
}
