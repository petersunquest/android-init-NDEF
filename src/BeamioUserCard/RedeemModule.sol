// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./BeamioERC1155Logic.sol";
import "./GovernanceStorage.sol";
import "./RedeemStorage.sol";

/* =========================
   Context interfaces (delegatecall)
   ========================= */

interface IUserCardCtx {
    function owner() external view returns (address);
    function factoryGateway() external view returns (address);
}

/**
 * @title BeamioUserCardRedeemModuleVNext
 * @notice Delegatecall module. Storage lives in the UserCard (via SLOT).
 */
contract BeamioUserCardRedeemModuleVNext {
    using RedeemStorage for RedeemStorage.Layout;
    uint256 private constant POINTS_ID = BeamioERC1155Logic.POINTS_ID;
    uint256 private constant _MAX_BUNDLE_LEN = 64;
    uint256 private constant _MAX_POOL_CONTAINERS = 32;

    // ===== events =====
    event RedeemCreated(bytes32 indexed hash, uint256 points6, uint256 attr, uint64 validAfter, uint64 validBefore, uint256 bundleLen);
    event RedeemCancelled(bytes32 indexed hash);
    event RedeemConsumed(bytes32 indexed hash, address indexed user, uint256 points6, uint256 attr, uint64 validAfter, uint64 validBefore, uint256 bundleLen);

    event RedeemPoolCreated(bytes32 indexed poolHash, uint64 validAfter, uint64 validBefore, uint256 containerTypes, uint256 totalRemaining);
    event RedeemPoolTerminated(bytes32 indexed poolHash);
    event RedeemPoolConsumed(bytes32 indexed poolHash, address indexed user, uint256 containerIndex, uint256 bundleLen);

    event RedeemAdminCreated(bytes32 indexed hash, uint64 validAfter, uint64 validBefore);
    event RedeemAdminConsumed(bytes32 indexed hash, address indexed to);

    // ==========================================================
    // access control (card owner OR gateway)
    // ==========================================================
    modifier onlyOwnerOrGateway() {
        address cardOwner = IUserCardCtx(address(this)).owner();
        address gw = IUserCardCtx(address(this)).factoryGateway();
        if (msg.sender != cardOwner && msg.sender != gw) revert BM_NotAuthorized();
        _;
    }

    modifier onlyGateway() {
        if (msg.sender != IUserCardCtx(address(this)).factoryGateway()) revert UC_UnauthorizedGateway();
        _;
    }

    // ==========================================================
    // helpers
    // ==========================================================
    function _validateBundle(uint256[] calldata tokenIds, uint256[] calldata amounts) internal pure {
        if (tokenIds.length != amounts.length) revert UC_InvalidProposal();
        for (uint256 i = 0; i < amounts.length; i++) {
            if (amounts[i] == 0) revert UC_AmountZero();
        }
    }

    function _timeOk(uint64 validAfter, uint64 validBefore) internal view returns (bool) {
        uint256 nowTs = block.timestamp;
        if (validAfter != 0 && nowTs < validAfter) return false;
        if (validBefore != 0 && nowTs > validBefore) return false;
        return true;
    }

    function _wipeRedeemArrays(RedeemStorage.Redeem storage r) internal {
        if (r.tokenIds.length != 0) delete r.tokenIds;
        if (r.amounts.length != 0) delete r.amounts;
    }

    function _requireValidRedeemRecommender(address recommender) internal view {
        if (recommender == address(0)) return;
        if (!GovernanceStorage.layout().isAdmin[recommender]) revert UC_NotAdmin();
    }

    // ==========================================================
    // One-time Redeem（仅 card owner 可创建，经 gateway executeForOwner 执行）
    // ==========================================================
    function createRedeem(
        bytes32 hash,
        uint256 points6,
        uint256 attr,
        uint64 validAfter,
        uint64 validBefore,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external onlyGateway {
        if (hash == bytes32(0)) revert BM_InvalidSecret();
        _validateBundle(tokenIds, amounts);

        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (r.active) revert UC_InvalidProposal();

        _wipeRedeemArrays(r);

        r.points6 = uint128(points6);
        r.attr = uint32(attr);
        r.validAfter = validAfter;
        r.validBefore = validBefore;
        r.active = true;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            r.tokenIds.push(tokenIds[i]);
            r.amounts.push(amounts[i]);
        }

        emit RedeemCreated(hash, points6, attr, validAfter, validBefore, tokenIds.length);
    }

    function createRedeem(
        bytes32 hash,
        uint256 points6,
        uint256 attr,
        uint64 validAfter,
        uint64 validBefore,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts,
        address recommender
    ) external onlyGateway {
        _requireValidRedeemRecommender(recommender);
        if (hash == bytes32(0)) revert BM_InvalidSecret();
        _validateBundle(tokenIds, amounts);

        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (r.active) revert UC_InvalidProposal();

        _wipeRedeemArrays(r);

        r.points6 = uint128(points6);
        r.attr = uint32(attr);
        r.validAfter = validAfter;
        r.validBefore = validBefore;
        r.creator = IUserCardCtx(address(this)).owner();
        r.recommender = recommender;
        r.active = true;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            r.tokenIds.push(tokenIds[i]);
            r.amounts.push(amounts[i]);
        }

        emit RedeemCreated(hash, points6, attr, validAfter, validBefore, tokenIds.length);
    }

    /// @notice 创建 redeem 并记录 creator（仅 gateway 调用，Factory executeForOwner 拦截后调用）。兑换时计入 creator 的 admin 统计及 parent 链
    function createRedeemWithCreator(
        bytes32 hash,
        uint256 points6,
        uint256 attr,
        uint64 validAfter,
        uint64 validBefore,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts,
        address creator
    ) external onlyGateway {
        if (hash == bytes32(0)) revert BM_InvalidSecret();
        _validateBundle(tokenIds, amounts);

        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (r.active) revert UC_InvalidProposal();

        _wipeRedeemArrays(r);

        r.points6 = uint128(points6);
        r.attr = uint32(attr);
        r.validAfter = validAfter;
        r.validBefore = validBefore;
        r.creator = creator;
        r.active = true;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            r.tokenIds.push(tokenIds[i]);
            r.amounts.push(amounts[i]);
        }

        emit RedeemCreated(hash, points6, attr, validAfter, validBefore, tokenIds.length);
    }

    /// @notice 创建 redeem 并记录 creator + recommender（仅 gateway 调用，Factory executeForOwner 拦截后调用）
    function createRedeemWithCreatorAndRecommender(
        bytes32 hash,
        uint256 points6,
        uint256 attr,
        uint64 validAfter,
        uint64 validBefore,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts,
        address creator,
        address recommender
    ) external onlyGateway {
        if (hash == bytes32(0)) revert BM_InvalidSecret();
        _validateBundle(tokenIds, amounts);

        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (r.active) revert UC_InvalidProposal();

        _wipeRedeemArrays(r);

        r.points6 = uint128(points6);
        r.attr = uint32(attr);
        r.validAfter = validAfter;
        r.validBefore = validBefore;
        r.creator = creator;
        r.recommender = recommender;
        r.active = true;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            r.tokenIds.push(tokenIds[i]);
            r.amounts.push(amounts[i]);
        }

        emit RedeemCreated(hash, points6, attr, validAfter, validBefore, tokenIds.length);
    }

    /// @notice 创建 redeem-admin：必须由 owner 离线签字后经 gateway 的 executeForOwner 执行。hash=keccak256(secretCode)
    function createRedeemAdmin(bytes32 hash, string calldata metadata, uint64 validAfter, uint64 validBefore) external onlyGateway {
        if (hash == bytes32(0)) revert BM_InvalidSecret();
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.RedeemAdmin storage ra = l.redeemAdmins[hash];
        if (ra.active) revert UC_InvalidProposal();
        ra.active = true;
        ra.metadata = metadata;
        ra.validAfter = validAfter;
        ra.validBefore = validBefore;
        emit RedeemAdminCreated(hash, validAfter, validBefore);
    }

    /// @notice 内部：校验 code 并消费 redeemAdmin，返回 metadata。仅由 card.redeemAdminByGateway 经 gateway 调用
    function consumeRedeemAdmin(string calldata code) external onlyGateway returns (string memory metadata) {
        bytes memory b = bytes(code);
        if (b.length == 0) revert BM_InvalidSecret();
        bytes32 hash = keccak256(b);
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.RedeemAdmin storage ra = l.redeemAdmins[hash];
        if (!ra.active) revert UC_InvalidProposal();
        if (!_timeOk(ra.validAfter, ra.validBefore)) revert UC_InvalidTimeWindow(block.timestamp, ra.validAfter, ra.validBefore);
        ra.active = false;
        metadata = ra.metadata;
        emit RedeemAdminConsumed(hash, msg.sender);
    }

    function cancelRedeem(string calldata code) external onlyOwnerOrGateway {
        bytes memory b = bytes(code);
        if (b.length == 0) revert BM_InvalidSecret();
        bytes32 hash = keccak256(b);

        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (!r.active) revert UC_InvalidProposal();

        r.active = false;
        _wipeRedeemArrays(r);

        emit RedeemCancelled(hash);
    }

    function consumeRedeem(string calldata code, address to)
        external
        returns (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts)
    {
        return _consumeRedeemUnified(code, to);
    }

    /// @notice 统一入口：根据 hash 查找 redeems 或 pools，自动分发处理
    function _consumeRedeemUnified(string calldata code, address to)
        internal
        returns (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts)
    {
        if (to == address(0)) revert BM_ZeroAddress();

        bytes memory b = bytes(code);
        if (b.length == 0) revert BM_InvalidSecret();
        bytes32 hash = keccak256(b);

        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        RedeemStorage.RedeemPool storage p = l.pools[hash];

        if (r.active) {
            return _consumeOneTime(r, hash, to);
        }
        if (p.active) {
            return _consumePoolToUnified(l, p, hash, to);
        }
        revert UC_InvalidProposal();
    }

    function _consumeOneTime(RedeemStorage.Redeem storage r, bytes32 hash, address to)
        internal
        returns (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts)
    {
        if (!_timeOk(r.validAfter, r.validBefore)) revert UC_InvalidTimeWindow(block.timestamp, r.validAfter, r.validBefore);
        r.active = false;

        points6 = r.points6;
        attr = r.attr;
        uint256 n = r.tokenIds.length;
        tokenIds = new uint256[](n);
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            tokenIds[i] = r.tokenIds[i];
            amounts[i] = r.amounts[i];
        }
        _wipeRedeemArrays(r);
        emit RedeemConsumed(hash, to, points6, attr, r.validAfter, r.validBefore, n);
    }

    function _consumePoolToUnified(RedeemStorage.Layout storage l, RedeemStorage.RedeemPool storage p, bytes32 poolHash, address user)
        internal
        returns (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts)
    {
        if (!_timeOk(p.validAfter, p.validBefore)) revert UC_InvalidTimeWindow(block.timestamp, p.validAfter, p.validBefore);
        if (p.totalRemaining == 0) revert UC_InvalidProposal();
        if (l.poolClaimed[poolHash][user]) revert UC_PoolAlreadyClaimed(poolHash, user);

        l.poolClaimed[poolHash][user] = true;

        uint256 m = p.containers.length;
        uint256 idx = p.cursor;
        for (uint256 k = 0; k < m; k++) {
            uint256 i = (idx + k) % m;
            if (p.containers[i].remaining != 0) {
                idx = i;
                break;
            }
            if (k == m - 1) revert UC_InvalidProposal();
        }

        RedeemStorage.PoolContainer storage c = p.containers[idx];
        c.remaining -= 1;
        p.totalRemaining -= 1;
        p.cursor = uint32((idx + 1) % m);

        uint256 n = c.tokenIds.length;
        tokenIds = new uint256[](n);
        amounts = new uint256[](n);
        for (uint256 j = 0; j < n; j++) {
            tokenIds[j] = c.tokenIds[j];
            amounts[j] = c.amounts[j];
        }
        emit RedeemPoolConsumed(poolHash, user, idx, n);
        return (0, 0, tokenIds, amounts);  // pool 无单独 points6/attr，由 tokenIds 含 POINTS_ID 表示
    }

    // ==========================================================
    // Batch One-time Redeem（一次多张相同类型的 Redeem）
    // ==========================================================
    /// @notice 批量创建多个 one-time redeem，内容相同。仅 card owner 可创建，经 gateway executeForOwner 执行
    function createRedeemBatch(
        bytes32[] calldata hashes,
        uint256 points6,
        uint256 attr,
        uint64 validAfter,
        uint64 validBefore,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external onlyGateway {
        if (hashes.length == 0) revert UC_InvalidProposal();
        _validateBundle(tokenIds, amounts);

        RedeemStorage.Layout storage l = RedeemStorage.layout();

        for (uint256 i = 0; i < hashes.length; i++) {
            if (hashes[i] == bytes32(0)) revert BM_InvalidSecret();
            RedeemStorage.Redeem storage r = l.redeems[hashes[i]];
            if (r.active) revert UC_InvalidProposal();

            _wipeRedeemArrays(r);
            r.points6 = uint128(points6);
            r.attr = uint32(attr);
            r.validAfter = validAfter;
            r.validBefore = validBefore;
            r.active = true;

            for (uint256 j = 0; j < tokenIds.length; j++) {
                r.tokenIds.push(tokenIds[j]);
                r.amounts.push(amounts[j]);
            }

            emit RedeemCreated(hashes[i], points6, attr, validAfter, validBefore, tokenIds.length);
        }
    }

    function createRedeemBatch(
        bytes32[] calldata hashes,
        uint256 points6,
        uint256 attr,
        uint64 validAfter,
        uint64 validBefore,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts,
        address recommender
    ) external onlyGateway {
        _requireValidRedeemRecommender(recommender);
        if (hashes.length == 0) revert UC_InvalidProposal();
        _validateBundle(tokenIds, amounts);

        RedeemStorage.Layout storage l = RedeemStorage.layout();

        for (uint256 i = 0; i < hashes.length; i++) {
            if (hashes[i] == bytes32(0)) revert BM_InvalidSecret();
            RedeemStorage.Redeem storage r = l.redeems[hashes[i]];
            if (r.active) revert UC_InvalidProposal();

            _wipeRedeemArrays(r);
            r.points6 = uint128(points6);
            r.attr = uint32(attr);
            r.validAfter = validAfter;
            r.validBefore = validBefore;
            r.creator = IUserCardCtx(address(this)).owner();
            r.recommender = recommender;
            r.active = true;

            for (uint256 j = 0; j < tokenIds.length; j++) {
                r.tokenIds.push(tokenIds[j]);
                r.amounts.push(amounts[j]);
            }

            emit RedeemCreated(hashes[i], points6, attr, validAfter, validBefore, tokenIds.length);
        }
    }

    /// @notice 批量创建 redeem 并记录 creator（仅 gateway 调用，Factory executeForOwner 拦截后调用）
    function createRedeemBatchWithCreator(
        bytes32[] calldata hashes,
        uint256 points6,
        uint256 attr,
        uint64 validAfter,
        uint64 validBefore,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts,
        address creator
    ) external onlyGateway {
        if (hashes.length == 0) revert UC_InvalidProposal();
        _validateBundle(tokenIds, amounts);

        RedeemStorage.Layout storage l = RedeemStorage.layout();

        for (uint256 i = 0; i < hashes.length; i++) {
            if (hashes[i] == bytes32(0)) revert BM_InvalidSecret();
            RedeemStorage.Redeem storage r = l.redeems[hashes[i]];
            if (r.active) revert UC_InvalidProposal();

            _wipeRedeemArrays(r);
            r.points6 = uint128(points6);
            r.attr = uint32(attr);
            r.validAfter = validAfter;
            r.validBefore = validBefore;
            r.creator = creator;
            r.active = true;

            for (uint256 j = 0; j < tokenIds.length; j++) {
                r.tokenIds.push(tokenIds[j]);
                r.amounts.push(amounts[j]);
            }

            emit RedeemCreated(hashes[i], points6, attr, validAfter, validBefore, tokenIds.length);
        }
    }

    /// @notice 批量创建 redeem 并记录 creator + recommender（仅 gateway 调用，Factory executeForOwner 拦截后调用）
    function createRedeemBatchWithCreatorAndRecommender(
        bytes32[] calldata hashes,
        uint256 points6,
        uint256 attr,
        uint64 validAfter,
        uint64 validBefore,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts,
        address creator,
        address recommender
    ) external onlyGateway {
        if (hashes.length == 0) revert UC_InvalidProposal();
        _validateBundle(tokenIds, amounts);

        RedeemStorage.Layout storage l = RedeemStorage.layout();

        for (uint256 i = 0; i < hashes.length; i++) {
            if (hashes[i] == bytes32(0)) revert BM_InvalidSecret();
            RedeemStorage.Redeem storage r = l.redeems[hashes[i]];
            if (r.active) revert UC_InvalidProposal();

            _wipeRedeemArrays(r);
            r.points6 = uint128(points6);
            r.attr = uint32(attr);
            r.validAfter = validAfter;
            r.validBefore = validBefore;
            r.creator = creator;
            r.recommender = recommender;
            r.active = true;

            for (uint256 j = 0; j < tokenIds.length; j++) {
                r.tokenIds.push(tokenIds[j]);
                r.amounts.push(amounts[j]);
            }

            emit RedeemCreated(hashes[i], points6, attr, validAfter, validBefore, tokenIds.length);
        }
    }

    /// @notice 批量 consume，智能处理：每个 code 可为 one-time 或 pool，统一聚合返回
    function consumeRedeemBatch(string[] calldata codes, address to)
        external
        returns (uint256 points6, uint256 attr, uint256[] memory tokenIds, uint256[] memory amounts)
    {
        if (to == address(0)) revert BM_ZeroAddress();
        if (codes.length == 0) revert UC_InvalidProposal();

        uint256 totalPoints6 = 0;
        uint256 firstAttr = 0;
        bool attrSet = false;
        uint256[] memory accT = new uint256[](128); // 预分配，单次 batch 通常不会超
        uint256[] memory accA = new uint256[](128);
        uint256 cursor = 0;

        for (uint256 c = 0; c < codes.length; c++) {
            if (bytes(codes[c]).length == 0) revert BM_InvalidSecret();
            for (uint256 d = 0; d < c; d++) {
                if (keccak256(bytes(codes[d])) == keccak256(bytes(codes[c]))) revert UC_InvalidProposal(); // 禁止重复
            }
            (uint256 p6, uint256 a, uint256[] memory tIds, uint256[] memory amts) = _consumeRedeemUnified(codes[c], to);
            totalPoints6 += p6;
            if (!attrSet && (a != 0 || tIds.length > 0)) { firstAttr = a; attrSet = true; }
            for (uint256 j = 0; j < tIds.length; j++) {
                if (cursor >= accT.length) revert UC_InvalidProposal(); // 超出预分配
                accT[cursor] = tIds[j];
                accA[cursor] = amts[j];
                cursor++;
            }
        }

        tokenIds = new uint256[](cursor);
        amounts = new uint256[](cursor);
        for (uint256 i = 0; i < cursor; i++) {
            tokenIds[i] = accT[i];
            amounts[i] = accA[i];
        }
        points6 = totalPoints6;
        attr = firstAttr;
    }

    // ==========================================================
    // RedeemPool（仅 card owner 可创建，经 gateway executeForOwner 执行）
    // ==========================================================
    function createRedeemPool(
        bytes32 poolHash,
        uint64 validAfter,
        uint64 validBefore,
        uint256[][] calldata tokenIdsList,
        uint256[][] calldata amountsList,
        uint32[] calldata counts
    ) external onlyGateway {
        if (poolHash == bytes32(0)) revert BM_InvalidSecret();

        uint256 m = tokenIdsList.length;
        if (m == 0) revert UC_InvalidProposal();
        if (amountsList.length != m || counts.length != m) revert UC_InvalidProposal();

        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.RedeemPool storage p = l.pools[poolHash];
        if (p.active) revert UC_InvalidProposal();

        // reset whole pool storage for reuse
        delete l.pools[poolHash];

        RedeemStorage.RedeemPool storage p2 = l.pools[poolHash];
        p2.active = true;
        p2.validAfter = validAfter;
        p2.validBefore = validBefore;
        p2.cursor = 0;

        uint256 total = 0;

        for (uint256 i = 0; i < m; i++) {
            _validateBundle(tokenIdsList[i], amountsList[i]);
            if (counts[i] == 0) revert UC_InvalidProposal();

            p2.containers.push();
            RedeemStorage.PoolContainer storage c = p2.containers[i];
            c.remaining = counts[i];

            for (uint256 j = 0; j < tokenIdsList[i].length; j++) {
                c.tokenIds.push(tokenIdsList[i][j]);
                c.amounts.push(amountsList[i][j]);
            }

            total += counts[i];
        }

        p2.totalRemaining = uint32(total);
        emit RedeemPoolCreated(poolHash, validAfter, validBefore, m, total);
    }

    function createRedeemPool(
        bytes32 poolHash,
        uint64 validAfter,
        uint64 validBefore,
        uint256[][] calldata tokenIdsList,
        uint256[][] calldata amountsList,
        uint32[] calldata counts,
        address recommender
    ) external onlyGateway {
        _requireValidRedeemRecommender(recommender);
        if (poolHash == bytes32(0)) revert BM_InvalidSecret();

        uint256 m = tokenIdsList.length;
        if (m == 0) revert UC_InvalidProposal();
        if (amountsList.length != m || counts.length != m) revert UC_InvalidProposal();

        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.RedeemPool storage p = l.pools[poolHash];
        if (p.active) revert UC_InvalidProposal();

        delete l.pools[poolHash];

        RedeemStorage.RedeemPool storage p2 = l.pools[poolHash];
        p2.active = true;
        p2.validAfter = validAfter;
        p2.validBefore = validBefore;
        p2.cursor = 0;
        p2.creator = IUserCardCtx(address(this)).owner();
        p2.recommender = recommender;

        uint256 total = 0;

        for (uint256 i = 0; i < m; i++) {
            _validateBundle(tokenIdsList[i], amountsList[i]);
            if (counts[i] == 0) revert UC_InvalidProposal();

            p2.containers.push();
            RedeemStorage.PoolContainer storage c = p2.containers[i];
            c.remaining = counts[i];

            for (uint256 j = 0; j < tokenIdsList[i].length; j++) {
                c.tokenIds.push(tokenIdsList[i][j]);
                c.amounts.push(amountsList[i][j]);
            }

            total += counts[i];
        }

        p2.totalRemaining = uint32(total);
        emit RedeemPoolCreated(poolHash, validAfter, validBefore, m, total);
    }

    /// @notice 创建 redeem pool 并记录 creator（仅 gateway 调用，Factory executeForOwner 拦截后调用）
    function createRedeemPoolWithCreator(
        bytes32 poolHash,
        uint64 validAfter,
        uint64 validBefore,
        uint256[][] calldata tokenIdsList,
        uint256[][] calldata amountsList,
        uint32[] calldata counts,
        address creator
    ) external onlyGateway {
        if (poolHash == bytes32(0)) revert BM_InvalidSecret();

        uint256 m = tokenIdsList.length;
        if (m == 0) revert UC_InvalidProposal();
        if (amountsList.length != m || counts.length != m) revert UC_InvalidProposal();

        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.RedeemPool storage p = l.pools[poolHash];
        if (p.active) revert UC_InvalidProposal();

        delete l.pools[poolHash];

        RedeemStorage.RedeemPool storage p2 = l.pools[poolHash];
        p2.active = true;
        p2.validAfter = validAfter;
        p2.validBefore = validBefore;
        p2.cursor = 0;
        p2.creator = creator;

        uint256 total = 0;

        for (uint256 i = 0; i < m; i++) {
            _validateBundle(tokenIdsList[i], amountsList[i]);
            if (counts[i] == 0) revert UC_InvalidProposal();

            p2.containers.push();
            RedeemStorage.PoolContainer storage c = p2.containers[i];
            c.remaining = counts[i];

            for (uint256 j = 0; j < tokenIdsList[i].length; j++) {
                c.tokenIds.push(tokenIdsList[i][j]);
                c.amounts.push(amountsList[i][j]);
            }

            total += counts[i];
        }

        p2.totalRemaining = uint32(total);
        emit RedeemPoolCreated(poolHash, validAfter, validBefore, m, total);
    }

    /// @notice 创建 redeem pool 并记录 creator + recommender（仅 gateway 调用，Factory executeForOwner 拦截后调用）
    function createRedeemPoolWithCreatorAndRecommender(
        bytes32 poolHash,
        uint64 validAfter,
        uint64 validBefore,
        uint256[][] calldata tokenIdsList,
        uint256[][] calldata amountsList,
        uint32[] calldata counts,
        address creator,
        address recommender
    ) external onlyGateway {
        if (poolHash == bytes32(0)) revert BM_InvalidSecret();

        uint256 m = tokenIdsList.length;
        if (m == 0) revert UC_InvalidProposal();
        if (amountsList.length != m || counts.length != m) revert UC_InvalidProposal();

        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.RedeemPool storage p = l.pools[poolHash];
        if (p.active) revert UC_InvalidProposal();

        delete l.pools[poolHash];

        RedeemStorage.RedeemPool storage p2 = l.pools[poolHash];
        p2.active = true;
        p2.validAfter = validAfter;
        p2.validBefore = validBefore;
        p2.cursor = 0;
        p2.creator = creator;
        p2.recommender = recommender;

        uint256 total = 0;

        for (uint256 i = 0; i < m; i++) {
            _validateBundle(tokenIdsList[i], amountsList[i]);
            if (counts[i] == 0) revert UC_InvalidProposal();

            p2.containers.push();
            RedeemStorage.PoolContainer storage c = p2.containers[i];
            c.remaining = counts[i];

            for (uint256 j = 0; j < tokenIdsList[i].length; j++) {
                c.tokenIds.push(tokenIdsList[i][j]);
                c.amounts.push(amountsList[i][j]);
            }

            total += counts[i];
        }

        p2.totalRemaining = uint32(total);
        emit RedeemPoolCreated(poolHash, validAfter, validBefore, m, total);
    }

    function terminateRedeemPool(bytes32 poolHash) external onlyOwnerOrGateway {
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.RedeemPool storage p = l.pools[poolHash];

        if (!p.active) revert UC_InvalidProposal();
        p.active = false;

        emit RedeemPoolTerminated(poolHash);
    }

    /// @notice Pool 专用入口（向后兼容），内部走统一 _consumeRedeemUnified 分发
    function consumeRedeemPool(string calldata code, address user)
        external
        returns (uint256[] memory tokenIds, uint256[] memory amounts)
    {
        (, , tokenIds, amounts) = _consumeRedeemUnified(code, user);
    }

    function _redeemTotalPoints(RedeemStorage.Redeem storage r) internal view returns (uint256) {
        uint256 t = r.points6;
        uint256 len = r.tokenIds.length;
        if (r.amounts.length < len) len = r.amounts.length;
        if (len > _MAX_BUNDLE_LEN) len = _MAX_BUNDLE_LEN;
        for (uint256 i = 0; i < len; i++) {
            if (r.tokenIds[i] == POINTS_ID) t += r.amounts[i];
        }
        return t;
    }

    function _poolTotalPoints(RedeemStorage.RedeemPool storage p) internal view returns (uint256) {
        uint256 t = 0;
        uint256 cLen = p.containers.length;
        if (cLen > _MAX_POOL_CONTAINERS) cLen = _MAX_POOL_CONTAINERS;
        for (uint256 c = 0; c < cLen; c++) {
            RedeemStorage.PoolContainer storage pc = p.containers[c];
            uint256 pcLen = pc.tokenIds.length;
            if (pc.amounts.length < pcLen) pcLen = pc.amounts.length;
            if (pcLen > _MAX_BUNDLE_LEN) pcLen = _MAX_BUNDLE_LEN;
            for (uint256 i = 0; i < pcLen; i++) {
                if (pc.tokenIds[i] == POINTS_ID) t += pc.amounts[i];
            }
        }
        return t;
    }

    function getRedeemStatus(bytes32 hash) external view returns (bool active, uint256 totalPoints6) {
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (r.active) return (true, _redeemTotalPoints(r));
        RedeemStorage.RedeemPool storage p = l.pools[hash];
        if (p.active && p.totalRemaining > 0) return (true, _poolTotalPoints(p));
        return (false, 0);
    }

    function getRedeemStatusBatch(string[] calldata codes) external view returns (bool[] memory active, uint256[] memory totalPoints6) {
        uint256 n = codes.length;
        active = new bool[](n);
        totalPoints6 = new uint256[](n);
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        for (uint256 i = 0; i < n; i++) {
            bytes32 hash = keccak256(bytes(codes[i]));
            RedeemStorage.Redeem storage r = l.redeems[hash];
            if (r.active) {
                active[i] = true;
                totalPoints6[i] = _redeemTotalPoints(r);
            } else {
                RedeemStorage.RedeemPool storage p = l.pools[hash];
                if (p.active && p.totalRemaining > 0) {
                    active[i] = true;
                    totalPoints6[i] = _poolTotalPoints(p);
                }
            }
        }
    }

    function getRedeemStatusBatch(bytes32[] calldata hashes) external view returns (bool[] memory active, uint256[] memory totalPoints6) {
        uint256 n = hashes.length;
        active = new bool[](n);
        totalPoints6 = new uint256[](n);
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        for (uint256 i = 0; i < n; i++) {
            RedeemStorage.Redeem storage r = l.redeems[hashes[i]];
            if (r.active) {
                active[i] = true;
                totalPoints6[i] = _redeemTotalPoints(r);
            } else {
                RedeemStorage.RedeemPool storage p = l.pools[hashes[i]];
                if (p.active && p.totalRemaining > 0) {
                    active[i] = true;
                    totalPoints6[i] = _poolTotalPoints(p);
                }
            }
        }
    }

    function getRedeemStatusEx(bytes32 hash, address claimer) external view returns (bool active, uint128 points6, bool isPool) {
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (r.active) return (true, r.points6, false);
        RedeemStorage.RedeemPool storage p = l.pools[hash];
        if (p.active && p.totalRemaining > 0) {
            if (claimer != address(0) && l.poolClaimed[hash][claimer]) return (false, 0, true);
            return (true, 0, true);
        }
        return (false, 0, false);
    }

    function getRedeemAdminStatus(bytes32 hash) external view returns (bool active) {
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.RedeemAdmin storage ra = l.redeemAdmins[hash];
        if (!ra.active) return false;
        uint64 va = ra.validAfter;
        uint64 vb = ra.validBefore;
        uint256 ts = block.timestamp;
        if (va != 0 && ts < va) return false;
        if (vb != 0 && ts > vb) return false;
        return true;
    }

    /// @notice 查询 redeem 的创建者（兑换前调用，用于 syncTokenAction operator 统计）。one-time 或 pool 均支持
    function getRedeemCreator(string calldata code) external view returns (address creator) {
        if (bytes(code).length == 0) return address(0);
        bytes32 hash = keccak256(bytes(code));
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (r.active) return r.creator;
        RedeemStorage.RedeemPool storage p = l.pools[hash];
        if (p.active) return p.creator;
        return address(0);
    }

    function getRedeemRecommender(string calldata code) external view returns (address recommender) {
        if (bytes(code).length == 0) return address(0);
        bytes32 hash = keccak256(bytes(code));
        RedeemStorage.Layout storage l = RedeemStorage.layout();
        RedeemStorage.Redeem storage r = l.redeems[hash];
        if (r.active) return r.recommender;
        RedeemStorage.RedeemPool storage p = l.pools[hash];
        if (p.active) return p.recommender;
        return address(0);
    }
}

