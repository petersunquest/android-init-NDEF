// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ====== Struct 定义 ======
struct Account {
    string accountName;
    string image;
    bool darkTheme;
    bool isUSDCFaucet;
    bool isETHFaucet;
    bool initialLoading;
    string firstName;   // 为空字符串表示未设置
    string lastName;    // 为空字符串表示未设置
    uint256 createdAt;  // 账号创建时间（block.timestamp，单位秒）
    bool exists;        // 是否已初始化
    string pgpKeyID;
    string pgpKey;
}

// 为了减少 setAccount 的参数数量，打包成一个输入 struct
struct AccountInput {
    string accountName;
    string image;
    bool darkTheme;
    bool isUSDCFaucet;
    bool isETHFaucet;
    bool initialLoading;
    string firstName;
    string lastName;
    string pgpKeyID;
    string pgpKey;
}

contract AccountRegistry {
    // ====== Errors ======
    error AccountNameAlreadyTaken();
    error AccountNotFound();
    error NotNameHashOwner();
    error NotAdmin();

    // ====== Admin 管理 ======
    mapping(address => bool) public _admin;

    modifier requireAddressInAdminlist() {
        if (!_admin[msg.sender]) revert NotAdmin();
        _;
    }

    constructor() {
        _admin[msg.sender] = true;
    }

    function changeAddressInAdminlist(address account, bool status)
        public
        requireAddressInAdminlist
    {
        _admin[account] = status;
    }

    function isAdmin(address account) public view returns (bool) {
        return _admin[account];
    }

    // ====== Account / Name / Base64 存储 ======

    // address -> Account
    mapping(address => Account) private accounts;

    // nameHash -> owner 地址（确保 hash 全局唯一）
    mapping(bytes32 => address) private nameHashOwner;

    // nameHash -> base64 数据
    mapping(bytes32 => string) private nameHashBase64;

    // 为了能分页遍历：记录出现过的 owner 列表（按创建顺序）
    address[] private allOwners;
    mapping(address => bool) private isInOwnerList;

    // ====== Follow 存储（仅关系 + 计数，不存地址数组） ======
    // follower -> followee -> bool
    mapping(address => mapping(address => bool)) private isFollowing;
    // address -> 我关注了多少人
    mapping(address => uint256) private followCount;
    // address -> 有多少人关注了我
    mapping(address => uint256) private followerCount;

    mapping (address=> string) public address2pgpPublicKey;
    mapping (bytes32 => address)  public pgpPublicKey2Address;



    // ====== Events ======
    event AccountUpdated(
        address indexed owner,
        bytes32 indexed nameHash,
        string accountName
    );

    event AccountDeleted(
        address indexed owner,
        bytes32 indexed nameHash,
        string accountName
    );

    event NameHashBase64Updated(
        bytes32 indexed nameHash,
        address indexed owner
    );

    /// @dev 关注关系由 mapping + 计数 + 事件组成，地址列表交给 DB 通过事件维护
    event FollowAdded(
        address indexed follower,
        address indexed followee,
        address indexed operator  // 谁发起的（自己 / admin）
    );

    event FollowRemoved(
        address indexed follower,
        address indexed followee,
        address indexed operator
    );

    // ====== 工具函数 ======

    /// @notice 计算 accountName 的 keccak256 hash（方便前端本地验证）
    function computeNameHash(string memory accountName) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(accountName));
    }

    // ====== 内部公共写入逻辑 ======

    /// @dev 内部通用写入逻辑：owner 可以是 msg.sender，也可以是 admin 代填的地址
    function _setAccount(address owner, AccountInput calldata input) internal {
        bytes32 newHash = keccak256(bytes(input.accountName));

        // 检查这个名字 hash 是否已经被其他人占用
        address currentOwner = nameHashOwner[newHash];
        if (currentOwner != address(0) && currentOwner != owner) {
            revert AccountNameAlreadyTaken();
        }

        Account storage acc = accounts[owner];

        // 如果 owner 已经有账号，并且改名了，则释放旧名字的 hash
        if (acc.exists) {
            bytes32 oldHash = keccak256(bytes(acc.accountName));

            if (oldHash != newHash && nameHashOwner[oldHash] == owner) {
                delete nameHashOwner[oldHash];
                // 如需删除旧名字对应的 base64，可打开：
                // delete nameHashBase64[oldHash];
            }
        } else {
            // 第一次创建，记录创建时间
            acc.createdAt = block.timestamp;

            // 首次出现这个 owner，记录进 allOwners，用于分页
            if (!isInOwnerList[owner]) {
                allOwners.push(owner);
                isInOwnerList[owner] = true;
            }
        }

        // 绑定新名字给当前地址
        nameHashOwner[newHash] = owner;

        // 更新 storage 中的账号信息（逐字段赋值，避免额外的 struct 临时变量）
        acc.accountName    = input.accountName;
        acc.image          = input.image;
        acc.darkTheme      = input.darkTheme;
        acc.isUSDCFaucet   = input.isUSDCFaucet;
        acc.isETHFaucet    = input.isETHFaucet;
        acc.initialLoading = input.initialLoading;
        acc.firstName      = input.firstName;
        acc.lastName       = input.lastName;
        acc.exists         = true;
        acc.pgpKeyID       = input.pgpKeyID;
        acc.pgpKey         = input.pgpKey;

        address2pgpPublicKey[owner] = input.pgpKey;
        pgpPublicKey2Address[computeNameHash(input.pgpKeyID)] = owner;

        emit AccountUpdated(owner, newHash, input.accountName);
    }

    // ====== Account 写入接口 ======

    /// @notice 创建或更新当前 msg.sender 的 Account
    function setAccount(AccountInput calldata input) external {
        _setAccount(msg.sender, input);
    }

    /// @notice 管理员代任意地址创建或更新 Account
    function setAccountByAdmin(address account, AccountInput calldata input)
        external
        requireAddressInAdminlist
    {
        _setAccount(account, input);
    }

    /// @notice 删除当前 msg.sender 对应的账号（释放名字 hash + base64）
    /// @dev follow / follower 关系依赖 DB，通过事件重建，这里不触碰 mapping
    function deleteMyAccount() external {
        address sender = msg.sender;
        Account storage acc = accounts[sender];
        if (!acc.exists) {
            revert AccountNotFound();
        }

        bytes32 hash = keccak256(bytes(acc.accountName));

        if (nameHashOwner[hash] == sender) {
            delete nameHashOwner[hash];
        }

        delete nameHashBase64[hash];

        string memory name = acc.accountName; // 先读出来给 event 用
        delete accounts[sender];

        emit AccountDeleted(sender, hash, name);
        // allOwners / isInOwnerList 不动，避免重排数组；分页时根据 exists 过滤
        // followCount / followerCount 也不改，视为历史统计；DB 可按需修正
    }

    // ====== Follow 相关（链上只维护 bool + count，地址列表交给 DB） ======

    /// @notice msg.sender 关注 toAccount
    function follow(address toAccount) external {
        address follower = msg.sender;

        require(toAccount != address(0), "invalid toAccount");
        require(toAccount != follower, "cannot follow self");

        if (!accounts[follower].exists || !accounts[toAccount].exists) {
            revert AccountNotFound();
        }

        // 已经关注过则直接返回，不重复加计数
        if (isFollowing[follower][toAccount]) {
            return;
        }

        isFollowing[follower][toAccount] = true;

        unchecked {
            followCount[follower] += 1;
            followerCount[toAccount] += 1;
        }

        emit FollowAdded(follower, toAccount, msg.sender);
    }

    /// @notice msg.sender 取消关注 toAccount
    function unfollow(address toAccount) external {
        address follower = msg.sender;

        require(toAccount != address(0), "invalid toAccount");
        require(toAccount != follower, "cannot unfollow self");

        if (!accounts[follower].exists || !accounts[toAccount].exists) {
            revert AccountNotFound();
        }

        // 如果本来就没关注，直接返回
        if (!isFollowing[follower][toAccount]) {
            return;
        }

        isFollowing[follower][toAccount] = false;

        unchecked {
            // 这里假设计数和关系是同步维护的，正常不会 underflow
            if (followCount[follower] > 0) {
                followCount[follower] -= 1;
            }
            if (followerCount[toAccount] > 0) {
                followerCount[toAccount] -= 1;
            }
        }

        emit FollowRemoved(follower, toAccount, msg.sender);
    }

    /// @notice 管理员代某个地址 follow 别人
    function followByAdmin(address follower, address toAccount)
        external
        requireAddressInAdminlist
    {
        require(toAccount != address(0), "invalid toAccount");
        require(toAccount != follower, "cannot follow self");

        if (!accounts[follower].exists || !accounts[toAccount].exists) {
            revert AccountNotFound();
        }

        if (isFollowing[follower][toAccount]) {
            return;
        }

        isFollowing[follower][toAccount] = true;

        unchecked {
            followCount[follower] += 1;
            followerCount[toAccount] += 1;
        }

        emit FollowAdded(follower, toAccount, msg.sender);
    }

    /// @notice 管理员代某个地址取消对别人的关注
    function unfollowByAdmin(address follower, address toAccount)
        external
        requireAddressInAdminlist
    {
        require(toAccount != address(0), "invalid toAccount");
        require(toAccount != follower, "cannot unfollow self");

        if (!accounts[follower].exists || !accounts[toAccount].exists) {
            revert AccountNotFound();
        }

        if (!isFollowing[follower][toAccount]) {
            return;
        }

        isFollowing[follower][toAccount] = false;

        unchecked {
            if (followCount[follower] > 0) {
                followCount[follower] -= 1;
            }
            if (followerCount[toAccount] > 0) {
                followerCount[toAccount] -= 1;
            }
        }

        emit FollowRemoved(follower, toAccount, msg.sender);
    }

    /// @notice 查询 follower 是否已经关注 followee
    function isFollowingAddress(address follower, address followee)
        external
        view
        returns (bool)
    {
        return isFollowing[follower][followee];
    }

    /// @notice 查询某个地址 follow 了多少人
    function getFollowCount(address owner) external view returns (uint256) {
        return followCount[owner];
    }

    /// @notice 查询某个地址有多少人关注
    function getFollowerCount(address owner) external view returns (uint256) {
        return followerCount[owner];
    }

    // ====== 读接口：单个查询 / 概要 ======

    function getAccount(address owner) external view returns (Account memory) {
        Account memory acc = accounts[owner];
        if (!acc.exists) {
            revert AccountNotFound();
        }
        return acc;
    }

    function getAccountByNameHash(bytes32 nameHash)
        external
        view
        returns (Account memory acc, address owner)
    {
        owner = nameHashOwner[nameHash];
        if (owner == address(0)) {
            revert AccountNotFound();
        }
        acc = accounts[owner];
        if (!acc.exists) {
            revert AccountNotFound();
        }
    }

    function isAccountNameAvailable(string calldata accountName)
        external
        view
        returns (bool)
    {
        bytes32 h = keccak256(bytes(accountName));
        return nameHashOwner[h] == address(0);
    }

    function getOwnerByAccountName(string calldata accountName)
        external
        view
        returns (address)
    {
        bytes32 h = keccak256(bytes(accountName));
        return nameHashOwner[h];
    }

    /// @notice 通过钱包地址读取用户名（accountName）
    function getUsernameByAddress(address owner)
        external
        view
        returns (string memory)
    {
        Account memory acc = accounts[owner];
        if (!acc.exists) revert AccountNotFound();
        return acc.accountName;
    }

    /// @notice 通过钱包地址读取用户名 + 创建时间 + follow/follower 数量
    function getUserSummary(address owner)
        external
        view
        returns (
            string memory username,
            uint256 createdAt,
            uint256 _followCount,
            uint256 _followerCount
        )
    {
        Account memory acc = accounts[owner];
        if (!acc.exists) revert AccountNotFound();

        username = acc.accountName;
        createdAt = acc.createdAt;
        _followCount = followCount[owner];
        _followerCount = followerCount[owner];
    }

    // ====== 读接口：分页查询全部地址 -> 用户名（倒序 + timestamp） ======

    /// @notice 分页返回所有「仍然存在的」账号 (wallet -> accountName)，按创建时间倒序
    /// @param cursor 已从「最新创建用户」方向跳过的原始 allOwners 位置数量
    /// @param pageSize 本页最多返回多少条
    /// @return owners 地址数组（最新创建的在前）
    /// @return names 对应用户名
    /// @return timestamps 对应 createdAt
    /// @return nextCursor 下一页游标（继续从最新往旧扫）
    function getAccountsPaginated(uint256 cursor, uint256 pageSize)
        external
        view
        returns (
            address[] memory owners,
            string[] memory names,
            uint256[] memory timestamps,
            uint256 nextCursor
        )
    {
        uint256 length = allOwners.length;
        if (length == 0 || pageSize == 0 || cursor >= length) {
            return (
                owners,
                names,
                timestamps,
                nextCursor
            );
        }

        // 从数组末尾往前走；cursor 表示从末尾（最新）已经跳过多少个原始索引
        uint256 consumed = 0; // 本次扫描消耗的原始索引个数
        uint256 count = 0;    // 实际返回的有效账号数量
        uint256 startIndex = length - 1 - cursor;

        // 第一次遍历：统计本页有效账号数量
        uint256 idxScan = startIndex;
        while (true) {
            address owner = allOwners[idxScan];
            if (accounts[owner].exists) {
                count++;
            }

            consumed++;
            if (consumed == pageSize) break;
            if (idxScan == 0) break;
            unchecked { idxScan--; }
        }

        nextCursor = cursor + consumed;

        owners = new address[](count);
        names = new string[](count);
        timestamps = new uint256[](count);

        // 第二次遍历：填充返回数组
        uint256 j = 0;
        consumed = 0;
        idxScan = startIndex;

        while (true) {
            address owner2 = allOwners[idxScan];
            Account storage acc = accounts[owner2];

            if (acc.exists) {
                owners[j] = owner2;
                names[j] = acc.accountName;
                timestamps[j] = acc.createdAt;
                j++;
            }

            consumed++;
            if (consumed == (nextCursor - cursor)) break;
            if (idxScan == 0) break;
            unchecked { idxScan--; }
        }
    }

    /// @notice 返回内部 owner 列表总长度（包含被删账号的洞位，仅用于前端参考）
    function getOwnersArrayLength() external view returns (uint256) {
        return allOwners.length;
    }

    // ====== base64 存取接口（按 hash） ======

    /// @notice 为当前账号设置 / 更新 base64 数据（例如头像原图）
    function setMyBase64(string calldata base64Data) external {
        address sender = msg.sender;
        Account storage acc = accounts[sender];
        if (!acc.exists) {
            revert AccountNotFound();
        }

        bytes32 h = keccak256(bytes(acc.accountName));
        nameHashBase64[h] = base64Data;

        emit NameHashBase64Updated(h, sender);
    }

    /// @notice 直接指定 nameHash 设置 base64，只有该 nameHash 的 owner 可以调用
    function setBase64ByNameHash(bytes32 nameHash, string calldata base64Data) external {
        address owner = nameHashOwner[nameHash];
        if (owner == address(0)) {
            revert AccountNotFound();
        }
        if (owner != msg.sender) {
            revert NotNameHashOwner();
        }

        nameHashBase64[nameHash] = base64Data;

        emit NameHashBase64Updated(nameHash, msg.sender);
    }

    function getBase64ByNameHash(bytes32 nameHash)
        external
        view
        returns (string memory)
    {
        return nameHashBase64[nameHash];
    }

    function getBase64ByAccountName(string calldata accountName)
        external
        view
        returns (string memory)
    {
        bytes32 h = keccak256(bytes(accountName));
        return nameHashBase64[h];
    }

    function setBase64(bytes32 hash, string calldata base64Data) external {
        address owner = nameHashOwner[hash];
        if (owner != address(0) && owner != msg.sender) {
            revert AccountNotFound();
        }

        nameHashBase64[hash] = base64Data;

        emit NameHashBase64Updated(hash, msg.sender);
    }

    /// @notice admin 版本：在不与既有用户冲突的前提下，为用户保存/更新 hash 对应的 base64
    ///         - 如果 hash == keccak(accountName)，则视为用户名标准 hash
    ///         - 否则视为自定义 hash，前提是不踩到其他用户
    function setBase64NameByAdmin(
        bytes32 hash,
        string calldata base64Data,
        string calldata accountName,
        address to
    ) external requireAddressInAdminlist {
        bytes32 h = keccak256(bytes(accountName));
        address ownerOfName = nameHashOwner[h];

        // 情况 1：hash == 用户名的标准 hash
        if (hash == h) {
            // 必须：这个名字属于 to 或 尚未绑定
            if (ownerOfName == address(0) || ownerOfName == to) {
                // 确保名称映射正确（owner == 0 的情况下）
                if (ownerOfName == address(0)) {
                    nameHashOwner[h] = to;
                }

                // 可安全写入 base64
                nameHashBase64[hash] = base64Data;
                emit NameHashBase64Updated(hash, to);
            }

            // 如果不符合条件（属于他人）→ 静默跳过，不写不报错
            return;
        }

        // 情况 2：自定义 hash（hash != keccak(accountName)）
        address hashOwner = nameHashOwner[hash];

        // 允许写入的条件：
        // 1. hash 未被占用
        // 2. hash 已经属于 to
        if (hashOwner == address(0) || hashOwner == to) {
            nameHashBase64[hash] = base64Data;
            emit NameHashBase64Updated(hash, to);
        }

        // 若 hash 属于他人 → 静默跳过，不写不报错
    }

    
}
