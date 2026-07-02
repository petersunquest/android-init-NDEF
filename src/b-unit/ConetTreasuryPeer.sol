// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ConetTreasuryPeerWrappedLib} from "./ConetTreasuryPeerWrappedLib.sol";
import {ConetTreasuryPeerStableSwapLib} from "./ConetTreasuryPeerStableSwapLib.sol";

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

interface IBurnableFactoryERC20 {
    function burnFrom(address account, uint256 amount) external;
}

interface IConetTreasuryFactoryMinter {
    function mintFactoryToken(address token, address to, uint256 amount) external;
    function burnFactoryFrom(address token, address account, uint256 amount) external;
    function registerPeerWrappedToken(address wrapped, uint256 peerChainId, address peerToken) external;
}

interface IConetTreasuryGovernance {
    function isMiner(address account) external view returns (bool);
    function minerCount() external view returns (uint256);
}

interface IConetGB1155 {
    function issueGB(address to, uint256 amountGB18) external;
    function revokeTotalOnly(address from, uint256 amountGB18) external;
}

interface IBeamioBUnitsBridge {
    function mintPaid(address to, uint256 amount) external;
    function consumeFuel(address user, uint256 amount) external returns (uint256 paidBurned);
    /// @dev 跨链 burn：仅 paidPool；不可烧 freePool。
    function consumePaidFuel(address user, uint256 amount) external returns (uint256 paidBurned);
    function bridgeableBalanceOf(address account) external view returns (uint256);
}

/// @dev GBToken ERC20（9 decimals）：Peer 须为 admin；跨链仅 paidPool（mintPaid / burnPaidFrom）。
interface IGBTokenErc20Bridge {
    function mintPaid(address to, uint256 amount) external;
    function burnPaidFrom(address account, uint256 amount) external;
    function bridgeableBalanceOf(address account) external view returns (uint256);
}

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title ConetTreasuryPeer
 * @dev 跨链 peer 桥模块（各链 Nick CREATE2 同址；constructor 固定 Treasury 同址）。
 *      Relayer 监听源链 BridgeOut 事件，在目标链对本合约 voteMintFromPeerDeposit / voteMintFromPeerCredit。
 *      包装 ERC20 minter 为 Treasury；本模块经 mintFactoryToken / burnFactoryFrom 代操作。
 * @notice UI / API 跨链与 Swap 协议见 `src/b-unit/conet-treasury-cross-chain-usage.md`
 */
contract ConetTreasuryPeer {
    address public immutable treasury;

    mapping(address => uint256) private _peerChainIdOf;
    mapping(address => address) private _peerTokenOf;
    mapping(address => bool) private _isWrappedToken;
    address[] private _wrappedTokens;

    struct PeerTokenMeta {
        string name;
        string symbol;
        uint8 decimals;
        bool registered;
    }
    mapping(bytes32 => PeerTokenMeta) private _peerTokens;

    struct PeerDepositProposal {
        uint256 peerChainId;
        address peerToken;
        address recipient;
        uint256 amount;
        uint8 creditAssetKind;
        uint256 voteCount;
        bool executed;
    }
    mapping(bytes32 => PeerDepositProposal) public peerDepositProposals;
    mapping(bytes32 => mapping(address => bool)) public hasVotedPeerDeposit;

    address public wrappedConet;
    address public buint;
    address public conetGB;
    /// @dev 可转账 ERC20 GB（GBToken CREATE2 同址）；非 1155 记账 GB。
    address public gbTokenErc20;
    /// @dev 本链 canonical USDC（ConetTreasury FactoryERC20，如 conet-USDC；Base 可为 Circle USDC 若 Treasury 可 mint）。
    address public usdcErc20;

    /// @dev 1 整 GB（1e9 最小单位）的 USDC6 标价；GB↔USDC 兑换用。例：0.01 USDC/GB → 10000。
    uint256 public usdc6PerFullGb;

    /// @dev 与 ConetTreasury / BUnitAirdrop 一致：1 USDC(6) = 100 B-Unit(6)。
    uint256 public constant USDC_TO_BUNIT_RATE = 100;

    /// @dev CoNET 专用：各 **目标链** 仍可兑现的跨出 USDC 额度（USDC6）。miner 按对端国库 USDC 储备维护。
    mapping(uint256 => uint256) public usdcOutboundBalance;

    /// @dev canonical ERC20 peer 种类（registerCanonicalErc20Peer）。
    uint8 public constant CANONICAL_NONE = 0;
    uint8 public constant CANONICAL_GB_ERC20 = 1;
    uint8 public constant CANONICAL_USDC_ERC20 = 2;
    uint8 public constant CANONICAL_BUINT_ERC20 = 3;
    uint8 public constant CANONICAL_WCNET_ERC20 = 4;

    /// @dev 用户跨链入口 `bridgeNativeAsset` 的原生资产 id（GB / B-Unit / wCNET，各链同址）。
    uint8 public constant NATIVE_ASSET_GB = 1;
    uint8 public constant NATIVE_ASSET_BUINT = 2;
    uint8 public constant NATIVE_ASSET_WCNET = 3;

    /// @dev (peerChainId, peerToken) → canonical kind；入桥 mint 至本链 gbTokenErc20 / usdcErc20 / buint。
    mapping(bytes32 => uint8) private _canonicalErc20Kind;

    uint256 public constant CONET_CHAIN_ID = 224422;
    address public constant NATIVE_PEER_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public constant BUINT_PEER_TOKEN = 0x000000000000000000000000000000000000B001;
    address public constant GB_PEER_TOKEN = 0x000000000000000000000000000000000000B002;

    event PeerTokenRegistered(
        uint256 indexed peerChainId,
        address indexed peerToken,
        string name,
        string symbol,
        uint8 decimals,
        address predictedWrapped
    );
    event WrappedTokenDeployed(uint256 indexed peerChainId, address indexed peerToken, address indexed wrappedToken);
    event PeerDepositProposalCreated(
        bytes32 indexed depositTxHash,
        uint256 peerChainId,
        address peerToken,
        address recipient,
        uint256 amount,
        address indexed firstVoter
    );
    event PeerDepositVoted(bytes32 indexed depositTxHash, address indexed miner, uint256 voteCount);
    event PeerDepositExecuted(bytes32 indexed depositTxHash, address indexed mintTarget, address recipient, uint256 amount);
    event MintExecuted(address indexed token, address indexed to, uint256 amount);
    event NativeDeposited(address indexed user, uint256 amount);
    event NativeWithdrawn(address indexed user, uint256 amount);
    event WrappedConetBridgeOut(
        address indexed user,
        uint256 amount,
        uint256 destinationChainId,
        address indexed recipient
    );
    event BUintBridgeOut(
        address indexed user,
        uint256 amount,
        uint256 destinationChainId,
        address indexed recipient
    );
    event GBBridgeOut(
        address indexed user,
        uint256 amountGB18,
        uint256 destinationChainId,
        address indexed recipient
    );
    event BUintUpdated(address indexed oldBuint, address indexed newBuint);
    event ConetGBUpdated(address indexed oldGb, address indexed newGb);
    event GbTokenErc20Updated(address indexed oldToken, address indexed newToken);
    event UsdcErc20Updated(address indexed oldToken, address indexed newToken);
    event PeerCanonicalAssetRegistered(uint256 indexed peerChainId, address indexed peerToken, string assetLabel);
    event GBIssueExecuted(bytes32 indexed txHash, address to, uint256 amountGB18);
    event UsdcBridgeOut(
        address indexed user,
        uint256 amount,
        uint256 destinationChainId,
        address indexed recipient
    );
    event NativeAssetBridgeOut(
        uint8 indexed nativeAsset,
        address indexed user,
        uint256 amount,
        uint256 destinationChainId,
        address indexed recipient
    );
    /// @dev 稳定币 / GB / B-Unit 跨链兑换出桥（源链 burn，目标链按 credit 字段 mint）。
    event StableSwapBridgeOut(
        address indexed user,
        uint8 indexed burnAssetKind,
        uint256 burnAmount,
        uint8 indexed creditAssetKind,
        uint256 creditAmount,
        uint256 destinationChainId,
        address recipient
    );
    event Usdc6PerFullGbUpdated(uint256 usdc6PerFullGb);
    event UsdcOutboundBalanceSet(uint256 indexed destinationChainId, uint256 balance);
    event UsdcOutboundBalanceReplenished(uint256 indexed destinationChainId, uint256 added, uint256 balance);
    event UsdcOutboundBalanceConsumed(uint256 indexed destinationChainId, uint256 amount, uint256 balance);

    error NotMiner();
    error AlreadyVoted();
    error ProposalNotExecutable();
    error ProposalAlreadyExecuted();
    error ProposalMismatch();
    error InvalidAmount();
    error InvalidTarget();
    error PeerTokenNotRegistered();
    error WrappedDeployFailed();
    error WrappedAddressMismatch();
    error WrappedConetNotRegistered();
    error BUintNotSet();
    error ConetGBNotSet();
    error GbTokenErc20NotSet();
    error UsdcErc20NotSet();
    error InvalidCanonicalKind();
    error InvalidNativeAsset();
    error NotConetChain();
    error TransferFailed();
    error WrappedTokenNotTracked();
    error EmptyTokenMetadata();
    error InsufficientOutboundUsdc();

    modifier onlyMiner() {
        if (!IConetTreasuryGovernance(treasury).isMiner(msg.sender)) revert NotMiner();
        _;
    }

    constructor(address treasury_) {
        if (treasury_ == address(0)) revert InvalidTarget();
        treasury = treasury_;
    }

    function requiredVotes() public view returns (uint256) {
        uint256 n = IConetTreasuryGovernance(treasury).minerCount();
        if (n == 0) return 0;
        return (n * 2 + 2) / 3;
    }

    function wrappedTokenCount() external view returns (uint256) {
        return _wrappedTokens.length;
    }

    function _peerKey(uint256 peerChainId, address peerToken) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(peerChainId, peerToken));
    }

    function _computeWrappedAddress(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 peerChainId,
        address peerToken
    ) internal view returns (address) {
        return ConetTreasuryPeerWrappedLib.computeWrappedAddress(
            treasury, name_, symbol_, decimals_, peerChainId, peerToken
        );
    }

    function registerPeerToken(
        uint256 peerChainId,
        address peerToken,
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_
    ) external onlyMiner returns (address predicted) {
        if (peerToken == address(0)) revert InvalidTarget();
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert EmptyTokenMetadata();
        bytes32 key = _peerKey(peerChainId, peerToken);
        PeerTokenMeta storage meta = _peerTokens[key];
        meta.name = name_;
        meta.symbol = symbol_;
        meta.decimals = decimals_;
        meta.registered = true;
        predicted = _computeWrappedAddress(name_, symbol_, decimals_, peerChainId, peerToken);
        emit PeerTokenRegistered(peerChainId, peerToken, name_, symbol_, decimals_, predicted);
    }

    function isPeerTokenRegistered(uint256 peerChainId, address peerToken) external view returns (bool) {
        return _peerTokens[_peerKey(peerChainId, peerToken)].registered;
    }

    function getPeerTokenMeta(uint256 peerChainId, address peerToken)
        external
        view
        returns (string memory name_, string memory symbol_, uint8 decimals_, bool registered)
    {
        PeerTokenMeta storage meta = _peerTokens[_peerKey(peerChainId, peerToken)];
        return (meta.name, meta.symbol, meta.decimals, meta.registered);
    }

    function peerChainIdOf(address wrappedToken) external view returns (uint256) {
        return _peerChainIdOf[wrappedToken];
    }

    function peerTokenOf(address wrappedToken) external view returns (address) {
        return _peerTokenOf[wrappedToken];
    }

    function predictWrappedToken(uint256 peerChainId, address peerToken) external view returns (address) {
        PeerTokenMeta storage meta = _peerTokens[_peerKey(peerChainId, peerToken)];
        if (!meta.registered) revert PeerTokenNotRegistered();
        return _computeWrappedAddress(meta.name, meta.symbol, meta.decimals, peerChainId, peerToken);
    }

    function _trackWrappedToken(address wrapped, uint256 peerChainId, address peerToken) internal {
        if (!_isWrappedToken[wrapped]) {
            _wrappedTokens.push(wrapped);
            _isWrappedToken[wrapped] = true;
        }
        _peerChainIdOf[wrapped] = peerChainId;
        _peerTokenOf[wrapped] = peerToken;
        IConetTreasuryFactoryMinter(treasury).registerPeerWrappedToken(wrapped, peerChainId, peerToken);
    }

    function _ensureWrappedToken(uint256 peerChainId, address peerToken) internal returns (address wrapped) {
        PeerTokenMeta storage meta = _peerTokens[_peerKey(peerChainId, peerToken)];
        if (!meta.registered) revert PeerTokenNotRegistered();

        wrapped = ConetTreasuryPeerWrappedLib.computeWrappedAddress(
            treasury, meta.name, meta.symbol, meta.decimals, peerChainId, peerToken
        );
        uint256 sizeBefore;
        assembly {
            sizeBefore := extcodesize(wrapped)
        }

        wrapped = ConetTreasuryPeerWrappedLib.ensureWrapped(
            treasury, meta.name, meta.symbol, meta.decimals, peerChainId, peerToken
        );

        _trackWrappedToken(wrapped, peerChainId, peerToken);
        if (sizeBefore == 0) {
            emit WrappedTokenDeployed(peerChainId, peerToken, wrapped);
        }
    }

    function deployWrappedToken(uint256 peerChainId, address peerToken) external returns (address wrapped) {
        return _ensureWrappedToken(peerChainId, peerToken);
    }

    function registerWrappedConetNative() external onlyMiner returns (address token) {
        bytes32 key = _peerKey(CONET_CHAIN_ID, NATIVE_PEER_TOKEN);
        PeerTokenMeta storage meta = _peerTokens[key];
        if (!meta.registered) {
            meta.name = "Wrapped CoNET";
            meta.symbol = "wCNET";
            meta.decimals = 18;
            meta.registered = true;
            token = _computeWrappedAddress(meta.name, meta.symbol, meta.decimals, CONET_CHAIN_ID, NATIVE_PEER_TOKEN);
            emit PeerTokenRegistered(
                CONET_CHAIN_ID, NATIVE_PEER_TOKEN, meta.name, meta.symbol, meta.decimals, token
            );
        }
        token = _ensureWrappedToken(CONET_CHAIN_ID, NATIVE_PEER_TOKEN);
        wrappedConet = token;
    }

    function predictWrappedConetNative() external view returns (address) {
        PeerTokenMeta storage meta = _peerTokens[_peerKey(CONET_CHAIN_ID, NATIVE_PEER_TOKEN)];
        if (!meta.registered) revert PeerTokenNotRegistered();
        return _computeWrappedAddress(meta.name, meta.symbol, meta.decimals, CONET_CHAIN_ID, NATIVE_PEER_TOKEN);
    }

    function isWrappedConetToken(address token) external view returns (bool) {
        if (token == address(0)) return false;
        if (wrappedConet != address(0) && token == wrappedConet) return true;
        if (_peerChainIdOf[token] != CONET_CHAIN_ID) return false;
        return _peerTokenOf[token] == NATIVE_PEER_TOKEN;
    }

    function _requireWrappedConet() internal view returns (address w) {
        w = wrappedConet;
        if (w != address(0)) return w;
        PeerTokenMeta storage meta = _peerTokens[_peerKey(CONET_CHAIN_ID, NATIVE_PEER_TOKEN)];
        if (!meta.registered) revert WrappedConetNotRegistered();
        w = _computeWrappedAddress(meta.name, meta.symbol, meta.decimals, CONET_CHAIN_ID, NATIVE_PEER_TOKEN);
    }

    function depositNative() external payable {
        if (block.chainid != CONET_CHAIN_ID) revert NotConetChain();
        if (msg.value == 0) revert InvalidAmount();
        address w = _requireWrappedConet();
        uint256 size;
        assembly {
            size := extcodesize(w)
        }
        if (size == 0) revert WrappedConetNotRegistered();
        IConetTreasuryFactoryMinter(treasury).mintFactoryToken(w, msg.sender, msg.value);
        emit NativeDeposited(msg.sender, msg.value);
    }

    function withdrawNative(uint256 amount) external {
        if (block.chainid != CONET_CHAIN_ID) revert NotConetChain();
        if (amount == 0) revert InvalidAmount();
        address w = _requireWrappedConet();
        IConetTreasuryFactoryMinter(treasury).burnFactoryFrom(w, msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit NativeWithdrawn(msg.sender, amount);
    }

    receive() external payable {}

    function burnWrappedConetForBridge(uint256 amount, uint256 destinationChainId, address recipient) external {
        _burnWrappedConetForBridge(msg.sender, amount, destinationChainId, recipient);
    }

    /**
     * @notice 原生资产跨链统一入口：源链 burn，目标链 miner 投票 mint（同 CREATE2 代币地址）。
     * @param nativeAsset NATIVE_ASSET_GB | NATIVE_ASSET_BUINT | NATIVE_ASSET_WCNET
     */
    function bridgeNativeAsset(
        uint8 nativeAsset,
        uint256 amount,
        uint256 destinationChainId,
        address recipient
    ) external {
        if (nativeAsset == NATIVE_ASSET_GB) {
            _burnGbForBridge(msg.sender, amount, destinationChainId, recipient);
        } else if (nativeAsset == NATIVE_ASSET_BUINT) {
            _burnBUintForBridge(msg.sender, amount, destinationChainId, recipient);
        } else if (nativeAsset == NATIVE_ASSET_WCNET) {
            _burnWrappedConetForBridge(msg.sender, amount, destinationChainId, recipient);
        } else {
            revert InvalidNativeAsset();
        }
        emit NativeAssetBridgeOut(nativeAsset, msg.sender, amount, destinationChainId, recipient);
    }

    /// @dev 各链 CREATE2 同址原生 token（UI 展示 / approve 用）。
    function nativeAssetToken(uint8 nativeAsset) external view returns (address token, uint8 decimals) {
        if (nativeAsset == NATIVE_ASSET_GB) {
            token = gbTokenErc20;
            if (token == address(0)) revert GbTokenErc20NotSet();
            return (token, 9);
        }
        if (nativeAsset == NATIVE_ASSET_BUINT) {
            token = buint;
            if (token == address(0)) revert BUintNotSet();
            return (token, 6);
        }
        if (nativeAsset == NATIVE_ASSET_WCNET) {
            token = _requireWrappedConet();
            return (token, 18);
        }
        revert InvalidNativeAsset();
    }

    function isNativeCrossChainToken(address token) external view returns (bool) {
        if (token == address(0)) return false;
        if (gbTokenErc20 != address(0) && token == gbTokenErc20) return true;
        if (buint != address(0) && token == buint) return true;
        address w = wrappedConet;
        if (w == address(0)) {
            PeerTokenMeta storage meta = _peerTokens[_peerKey(CONET_CHAIN_ID, NATIVE_PEER_TOKEN)];
            if (!meta.registered) return false;
            w = _computeWrappedAddress(meta.name, meta.symbol, meta.decimals, CONET_CHAIN_ID, NATIVE_PEER_TOKEN);
        }
        return token == w;
    }

    function _burnWrappedConetForBridge(
        address user,
        uint256 amount,
        uint256 destinationChainId,
        address recipient
    ) internal {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidTarget();
        if (destinationChainId == block.chainid) revert InvalidTarget();
        address w = _requireWrappedConet();
        if (!_isWrappedToken[w]) revert WrappedTokenNotTracked();
        IConetTreasuryFactoryMinter(treasury).burnFactoryFrom(w, user, amount);
        emit WrappedConetBridgeOut(user, amount, destinationChainId, recipient);
    }

    function setBUint(address _buint) external onlyMiner {
        if (_buint == address(0)) revert InvalidTarget();
        address old = buint;
        buint = _buint;
        emit BUintUpdated(old, _buint);
    }

    function setConetGB(address _conetGB) external onlyMiner {
        if (_conetGB == address(0)) revert InvalidTarget();
        address oldGb = conetGB;
        conetGB = _conetGB;
        emit ConetGBUpdated(oldGb, _conetGB);
    }

    function setGbTokenErc20(address _gbTokenErc20) external onlyMiner {
        if (_gbTokenErc20 == address(0)) revert InvalidTarget();
        address old = gbTokenErc20;
        gbTokenErc20 = _gbTokenErc20;
        emit GbTokenErc20Updated(old, _gbTokenErc20);
    }

    function setUsdcErc20(address _usdcErc20) external onlyMiner {
        if (_usdcErc20 == address(0)) revert InvalidTarget();
        address old = usdcErc20;
        usdcErc20 = _usdcErc20;
        emit UsdcErc20Updated(old, _usdcErc20);
    }

    function setUsdc6PerFullGb(uint256 rate) external onlyMiner {
        if (rate == 0) revert InvalidAmount();
        usdc6PerFullGb = rate;
        emit Usdc6PerFullGbUpdated(rate);
    }

    /// @dev CoNET：设置某目标链可兑现跨出 USDC 总额（USDC6）。须与对端链 Treasury / Circle USDC 储备对账。
    function setUsdcOutboundBalance(uint256 destinationChainId, uint256 balance) external onlyMiner {
        if (block.chainid != CONET_CHAIN_ID) revert NotConetChain();
        if (destinationChainId == block.chainid) revert InvalidTarget();
        usdcOutboundBalance[destinationChainId] = balance;
        emit UsdcOutboundBalanceSet(destinationChainId, balance);
    }

    function replenishUsdcOutboundBalance(uint256 destinationChainId, uint256 amount) external onlyMiner {
        if (block.chainid != CONET_CHAIN_ID) revert NotConetChain();
        if (destinationChainId == block.chainid) revert InvalidTarget();
        if (amount == 0) revert InvalidAmount();
        usdcOutboundBalance[destinationChainId] += amount;
        emit UsdcOutboundBalanceReplenished(destinationChainId, amount, usdcOutboundBalance[destinationChainId]);
    }

    /// @dev CoNET：跨出 USDC 前可读可用额度 = min(记账额度, Treasury 本链 conet-USDC 余额)。
    function availableOutboundUsdc(uint256 destinationChainId) public view returns (uint256) {
        if (block.chainid != CONET_CHAIN_ID) return 0;
        uint256 booked = usdcOutboundBalance[destinationChainId];
        if (usdcErc20 == address(0)) return booked;
        uint256 treasBal = IERC20Balance(usdcErc20).balanceOf(treasury);
        return booked < treasBal ? booked : treasBal;
    }

    /// @dev CoNET 源链：跨出并在目标链 mint USDC 前扣减额度；不足则 revert（不 burn）。
    ///      适用于 `burnUsdcForBridge` 与 `bridgeStableSwap(..., creditKind=USDC)`（含 GB/B-Unit burn → 对端 USDC）。
    function _requireAndConsumeOutboundUsdcCredit(uint256 destinationChainId, uint8 creditAssetKind, uint256 creditAmountUsdc6)
        internal
    {
        if (creditAssetKind != CANONICAL_USDC_ERC20) return;
        _consumeOutboundUsdcLiquidity(destinationChainId, creditAmountUsdc6);
    }

    function _consumeOutboundUsdcLiquidity(uint256 destinationChainId, uint256 usdcAmount6) internal {
        if (block.chainid != CONET_CHAIN_ID) return;
        if (usdcAmount6 == 0) return;
        uint256 available = availableOutboundUsdc(destinationChainId);
        if (available < usdcAmount6) revert InsufficientOutboundUsdc();
        usdcOutboundBalance[destinationChainId] -= usdcAmount6;
        emit UsdcOutboundBalanceConsumed(destinationChainId, usdcAmount6, usdcOutboundBalance[destinationChainId]);
    }

    /// @dev CoNET 入站：对端链 USDC 跨入本链 mint 后，回补该链跨出 USDC 额度。
    function _replenishOutboundFromInboundUsdc(uint256 sourceChainId, uint256 usdcAmount6) internal {
        if (block.chainid != CONET_CHAIN_ID) return;
        if (sourceChainId == CONET_CHAIN_ID || usdcAmount6 == 0) return;
        usdcOutboundBalance[sourceChainId] += usdcAmount6;
        emit UsdcOutboundBalanceReplenished(sourceChainId, usdcAmount6, usdcOutboundBalance[sourceChainId]);
    }

    function quoteStableSwap(uint8 burnAssetKind, uint256 burnAmount, uint8 creditAssetKind)
        external
        view
        returns (uint256 creditAmount)
    {
        return ConetTreasuryPeerStableSwapLib.quoteStableSwap(
            burnAssetKind, burnAmount, creditAssetKind, usdc6PerFullGb, USDC_TO_BUNIT_RATE
        );
    }

    /**
     * @notice USDC / GB / B-Unit 兑换。
     *         **跨链**：`destinationChainId != block.chainid` — 源链 burn，Relayer 目标链 mint；CoNET 出 USDC 扣 `usdcOutboundBalance`。
     *         **本链**：`destinationChainId == block.chainid` — 须 USDC↔GB/B-Unit；burn + `mintPaid` 同 tx；不扣 outbound 额度。
     *         USDC→GB/B-Unit 须 `approve(ConetTreasury, amount)` on usdcErc20。
     */
    function bridgeStableSwap(
        uint8 burnAssetKind,
        uint256 amount,
        uint256 destinationChainId,
        address recipient,
        uint8 creditAssetKind
    ) external {
        if (amount == 0) revert InvalidAmount();
        if (burnAssetKind < CANONICAL_GB_ERC20 || burnAssetKind > CANONICAL_BUINT_ERC20
            || creditAssetKind < CANONICAL_GB_ERC20 || creditAssetKind > CANONICAL_BUINT_ERC20) {
            revert InvalidCanonicalKind();
        }

        bool isLocal = destinationChainId == block.chainid;
        address to = recipient;
        if (isLocal) {
            if (burnAssetKind == creditAssetKind
                || (burnAssetKind != CANONICAL_USDC_ERC20 && creditAssetKind != CANONICAL_USDC_ERC20)) {
                revert InvalidCanonicalKind();
            }
            if (to == address(0)) to = msg.sender;
        } else if (to == address(0)) {
            revert InvalidTarget();
        }

        uint256 creditAmount = ConetTreasuryPeerStableSwapLib.quoteStableSwap(
            burnAssetKind, amount, creditAssetKind, usdc6PerFullGb, USDC_TO_BUNIT_RATE
        );
        if (creditAmount == 0) revert InvalidAmount();

        if (isLocal) {
            _burnByStableKind(msg.sender, burnAssetKind, amount);
            _mintByStableKind(creditAssetKind, to, creditAmount);
        } else {
            _requireAndConsumeOutboundUsdcCredit(destinationChainId, creditAssetKind, creditAmount);
            _burnByStableKind(msg.sender, burnAssetKind, amount);
        }

        emit StableSwapBridgeOut(
            msg.sender, burnAssetKind, amount, creditAssetKind, creditAmount, destinationChainId, to
        );
    }

    /// @dev CoNET UI：预览兑换 mint 量，并在 credit=USDC 时返回跨出流动性是否足够。
    function previewStableSwapOutbound(
        uint8 burnAssetKind,
        uint256 burnAmount,
        uint256 destinationChainId,
        uint8 creditAssetKind
    ) external view returns (uint256 creditAmount, uint256 availableUsdc6, bool sufficient) {
        creditAmount = ConetTreasuryPeerStableSwapLib.quoteStableSwap(
            burnAssetKind, burnAmount, creditAssetKind, usdc6PerFullGb, USDC_TO_BUNIT_RATE
        );
        if (block.chainid != CONET_CHAIN_ID || creditAssetKind != CANONICAL_USDC_ERC20) {
            return (creditAmount, 0, true);
        }
        availableUsdc6 = availableOutboundUsdc(destinationChainId);
        sufficient = creditAmount <= availableUsdc6;
    }

    function _burnByStableKind(address user, uint8 kind, uint256 amount) internal {
        if (kind == CANONICAL_USDC_ERC20) {
            if (usdcErc20 == address(0)) revert UsdcErc20NotSet();
            IConetTreasuryFactoryMinter(treasury).burnFactoryFrom(usdcErc20, user, amount);
            return;
        }
        if (kind == CANONICAL_GB_ERC20) {
            if (gbTokenErc20 == address(0)) revert GbTokenErc20NotSet();
            IGBTokenErc20Bridge(gbTokenErc20).burnPaidFrom(user, amount);
            return;
        }
        if (kind == CANONICAL_BUINT_ERC20) {
            if (buint == address(0)) revert BUintNotSet();
            IBeamioBUnitsBridge(buint).consumePaidFuel(user, amount);
            return;
        }
        revert InvalidCanonicalKind();
    }

    function _mintByStableKind(uint8 kind, address recipient, uint256 amount) internal {
        if (kind == CANONICAL_USDC_ERC20) {
            if (usdcErc20 == address(0)) revert UsdcErc20NotSet();
            IConetTreasuryFactoryMinter(treasury).mintFactoryToken(usdcErc20, recipient, amount);
            emit MintExecuted(usdcErc20, recipient, amount);
            return;
        }
        if (kind == CANONICAL_GB_ERC20) {
            if (gbTokenErc20 == address(0)) revert GbTokenErc20NotSet();
            IGBTokenErc20Bridge(gbTokenErc20).mintPaid(recipient, amount);
            emit MintExecuted(gbTokenErc20, recipient, amount);
            return;
        }
        if (kind == CANONICAL_BUINT_ERC20) {
            if (buint == address(0)) revert BUintNotSet();
            IBeamioBUnitsBridge(buint).mintPaid(recipient, amount);
            emit MintExecuted(buint, recipient, amount);
            return;
        }
        revert InvalidCanonicalKind();
    }

    function canonicalErc20Kind(uint256 peerChainId, address peerToken) external view returns (uint8) {
        return _canonicalErc20Kind[_peerKey(peerChainId, peerToken)];
    }

    function _localTokenForCanonicalKind(uint8 kind) internal view returns (address local) {
        if (kind == CANONICAL_GB_ERC20) {
            local = gbTokenErc20;
            if (local == address(0)) revert GbTokenErc20NotSet();
            return local;
        }
        if (kind == CANONICAL_USDC_ERC20) {
            local = usdcErc20;
            if (local == address(0)) revert UsdcErc20NotSet();
            return local;
        }
        if (kind == CANONICAL_BUINT_ERC20) {
            local = buint;
            if (local == address(0)) revert BUintNotSet();
            return local;
        }
        if (kind == CANONICAL_WCNET_ERC20) {
            return _requireWrappedConet();
        }
        revert InvalidCanonicalKind();
    }

    function _registerCanonicalErc20Peer(
        uint256 peerChainId,
        address peerToken,
        uint8 kind,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) internal returns (address localToken) {
        if (peerToken == address(0)) revert InvalidTarget();
        if (kind < CANONICAL_GB_ERC20 || kind > CANONICAL_WCNET_ERC20) revert InvalidCanonicalKind();
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert EmptyTokenMetadata();

        localToken = _localTokenForCanonicalKind(kind);

        bytes32 key = _peerKey(peerChainId, peerToken);
        PeerTokenMeta storage meta = _peerTokens[key];
        meta.name = name_;
        meta.symbol = symbol_;
        meta.decimals = decimals_;
        meta.registered = true;
        _canonicalErc20Kind[key] = kind;

        emit PeerTokenRegistered(peerChainId, peerToken, name_, symbol_, decimals_, localToken);
    }

    /**
     * @dev 登记对端链 **真实 ERC20 地址** 为 canonical peer（非 0xB001/0xB002 占位符）。
     */
    function registerCanonicalErc20Peer(
        uint256 peerChainId,
        address peerToken,
        uint8 kind,
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_
    ) external onlyMiner returns (address localToken) {
        return _registerCanonicalErc20Peer(peerChainId, peerToken, kind, name_, symbol_, decimals_);
    }

    /**
     * @dev 原生跨链 trio：GB + B-Unit + wCNET（各链 CREATE2 **同址** token 作为 peerToken）。
     *      须先 setGbTokenErc20 / setBUint / registerWrappedConetNative。
     */
    function registerPeerNativeBridgeAssets(
        uint256[] calldata peerChainIds,
        address peerGbErc20,
        address peerBuintErc20,
        address peerWcnetErc20
    ) external onlyMiner {
        if (peerGbErc20 == address(0) || peerBuintErc20 == address(0) || peerWcnetErc20 == address(0)) {
            revert InvalidTarget();
        }
        for (uint256 i = 0; i < peerChainIds.length; i++) {
            uint256 pid = peerChainIds[i];
            _registerCanonicalErc20Peer(pid, peerGbErc20, CANONICAL_GB_ERC20, "CONET GB", "GB", 9);
            _registerCanonicalErc20Peer(pid, peerBuintErc20, CANONICAL_BUINT_ERC20, "Beamio Units", "B-UNITS", 6);
            _registerCanonicalErc20Peer(pid, peerWcnetErc20, CANONICAL_WCNET_ERC20, "Wrapped CoNET", "wCNET", 18);
        }
    }

    /**
     * @dev 稳定币互换 peer 登记：GB + B-Unit + USDC（对端链 **同 CREATE2 / 官方 USDC 地址**）。
     *      在 CoNET 上对 peerChainIds=[8453] 传 Base 侧 token 地址；在 Base 上对 [224422] 传 CoNET 侧地址。
     */
    function registerPeerStableSwapAssets(
        uint256[] calldata peerChainIds,
        address peerGbErc20,
        address peerBuintErc20,
        address peerUsdcErc20
    ) external onlyMiner {
        if (peerGbErc20 == address(0) || peerBuintErc20 == address(0) || peerUsdcErc20 == address(0)) {
            revert InvalidTarget();
        }
        for (uint256 i = 0; i < peerChainIds.length; i++) {
            uint256 pid = peerChainIds[i];
            _registerCanonicalErc20Peer(pid, peerGbErc20, CANONICAL_GB_ERC20, "CONET GB", "GB", 9);
            _registerCanonicalErc20Peer(pid, peerBuintErc20, CANONICAL_BUINT_ERC20, "Beamio Units", "B-UNITS", 6);
            _registerCanonicalErc20Peer(pid, peerUsdcErc20, CANONICAL_USDC_ERC20, "USD Coin", "USDC", 6);
        }
    }

    function _registerPeerCanonicalBridge(
        uint256 peerChainId,
        address peerToken,
        string memory assetLabel,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) internal {
        bytes32 key = _peerKey(peerChainId, peerToken);
        PeerTokenMeta storage meta = _peerTokens[key];
        meta.name = name_;
        meta.symbol = symbol_;
        meta.decimals = decimals_;
        meta.registered = true;
        emit PeerCanonicalAssetRegistered(peerChainId, peerToken, assetLabel);
        emit PeerTokenRegistered(peerChainId, peerToken, name_, symbol_, decimals_, address(0));
    }

    function registerPeerBUintBridge(uint256 peerChainId) external onlyMiner {
        _registerPeerCanonicalBridge(
            peerChainId, BUINT_PEER_TOKEN, "B-Units", "Beamio Units", "B-UNITS", 6
        );
    }

    function registerPeerGBBridge(uint256 peerChainId) external onlyMiner {
        _registerPeerCanonicalBridge(peerChainId, GB_PEER_TOKEN, "GB", "CoNET GB", "GB", 18);
    }

    function registerPeerBridgeAssets(uint256[] calldata peerChainIds) external onlyMiner {
        for (uint256 i = 0; i < peerChainIds.length; i++) {
            _registerPeerCanonicalBridge(
                peerChainIds[i], BUINT_PEER_TOKEN, "B-Units", "Beamio Units", "B-UNITS", 6
            );
            _registerPeerCanonicalBridge(peerChainIds[i], GB_PEER_TOKEN, "GB", "CoNET GB", "GB", 18);
        }
    }

    function burnBUintForBridge(uint256 amount, uint256 destinationChainId, address recipient) external {
        _burnBUintForBridge(msg.sender, amount, destinationChainId, recipient);
    }

    function _burnBUintForBridge(
        address user,
        uint256 amount,
        uint256 destinationChainId,
        address recipient
    ) internal {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidTarget();
        if (destinationChainId == block.chainid) revert InvalidTarget();
        if (buint == address(0)) revert BUintNotSet();
        IBeamioBUnitsBridge(buint).consumePaidFuel(user, amount);
        emit BUintBridgeOut(user, amount, destinationChainId, recipient);
    }

    function burnGBForBridge(uint256 amountGB18, uint256 destinationChainId, address recipient) external {
        _burnGbForBridge(msg.sender, amountGB18, destinationChainId, recipient);
    }

    function _burnGbForBridge(
        address user,
        uint256 amountGB18,
        uint256 destinationChainId,
        address recipient
    ) internal {
        if (amountGB18 == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidTarget();
        if (destinationChainId == block.chainid) revert InvalidTarget();
        if (gbTokenErc20 != address(0)) {
            IGBTokenErc20Bridge(gbTokenErc20).burnPaidFrom(user, amountGB18);
            emit GBBridgeOut(user, amountGB18, destinationChainId, recipient);
            return;
        }
        if (conetGB == address(0)) revert ConetGBNotSet();
        IConetGB1155(conetGB).revokeTotalOnly(user, amountGB18);
        emit GBBridgeOut(user, amountGB18, destinationChainId, recipient);
    }

    function burnUsdcForBridge(uint256 amount, uint256 destinationChainId, address recipient) external {
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidTarget();
        if (destinationChainId == block.chainid) revert InvalidTarget();
        if (usdcErc20 == address(0)) revert UsdcErc20NotSet();
        _requireAndConsumeOutboundUsdcCredit(destinationChainId, CANONICAL_USDC_ERC20, amount);
        IConetTreasuryFactoryMinter(treasury).burnFactoryFrom(usdcErc20, msg.sender, amount);
        emit UsdcBridgeOut(msg.sender, amount, destinationChainId, recipient);
    }

    function isCanonicalPeerToken(address peerToken) public pure returns (bool) {
        return peerToken == BUINT_PEER_TOKEN || peerToken == GB_PEER_TOKEN;
    }

    function voteMintFromPeerDeposit(
        bytes32 depositTxHash,
        uint256 peerChainId,
        address peerToken,
        address recipient,
        uint256 amount
    ) external onlyMiner {
        if (hasVotedPeerDeposit[depositTxHash][msg.sender]) revert AlreadyVoted();
        _applyPeerDepositVote(msg.sender, depositTxHash, peerChainId, peerToken, recipient, amount, 0);
    }

    /// @dev 跨链 **兑换** 入桥：mint `creditAssetKind` 数量 `creditAmount`（relayer 须与源链 StableSwapBridgeOut 一致）。
    function voteMintFromPeerCredit(
        bytes32 depositTxHash,
        uint256 sourceChainId,
        address sourcePeerToken,
        address recipient,
        uint256 creditAmount,
        uint8 creditAssetKind
    ) external onlyMiner {
        if (hasVotedPeerDeposit[depositTxHash][msg.sender]) revert AlreadyVoted();
        if (!ConetTreasuryPeerStableSwapLib.isStableSwapKind(creditAssetKind)) revert InvalidCanonicalKind();
        _applyPeerDepositVote(
            msg.sender, depositTxHash, sourceChainId, sourcePeerToken, recipient, creditAmount, creditAssetKind
        );
    }

    function executePeerDepositMint(bytes32 depositTxHash) external {
        _executePeerDepositMint(depositTxHash);
    }

    function _applyPeerDepositVote(
        address miner,
        bytes32 depositTxHash,
        uint256 peerChainId,
        address peerToken,
        address recipient,
        uint256 amount,
        uint8 creditAssetKind
    ) internal {
        if (peerToken == address(0) || recipient == address(0)) revert InvalidTarget();
        if (amount == 0) revert InvalidAmount();
        if (!_peerTokens[_peerKey(peerChainId, peerToken)].registered) revert PeerTokenNotRegistered();

        PeerDepositProposal storage p = peerDepositProposals[depositTxHash];
        if (p.executed) revert ProposalAlreadyExecuted();

        if (p.voteCount == 0) {
            p.peerChainId = peerChainId;
            p.peerToken = peerToken;
            p.recipient = recipient;
            p.amount = amount;
            p.creditAssetKind = creditAssetKind;
            p.voteCount = 1;
            emit PeerDepositProposalCreated(depositTxHash, peerChainId, peerToken, recipient, amount, miner);
        } else {
            if (
                p.peerChainId != peerChainId || p.peerToken != peerToken || p.recipient != recipient
                    || p.amount != amount || p.creditAssetKind != creditAssetKind
            ) revert ProposalMismatch();
            p.voteCount++;
        }

        hasVotedPeerDeposit[depositTxHash][miner] = true;
        emit PeerDepositVoted(depositTxHash, miner, p.voteCount);

        if (p.voteCount >= requiredVotes()) {
            _executePeerDepositMint(depositTxHash);
        }
    }

    function _executePeerDepositMint(bytes32 depositTxHash) internal {
        PeerDepositProposal storage p = peerDepositProposals[depositTxHash];
        if (p.executed) revert ProposalAlreadyExecuted();
        if (p.voteCount < requiredVotes()) revert ProposalNotExecutable();

        p.executed = true;

        if (p.creditAssetKind != 0) {
            _mintByStableKind(p.creditAssetKind, p.recipient, p.amount);
            if (p.creditAssetKind == CANONICAL_USDC_ERC20) {
                _replenishOutboundFromInboundUsdc(p.peerChainId, p.amount);
            }
            address mintTarget = _stableKindToken(p.creditAssetKind);
            emit PeerDepositExecuted(depositTxHash, mintTarget, p.recipient, p.amount);
            if (p.creditAssetKind == CANONICAL_GB_ERC20) {
                emit GBIssueExecuted(depositTxHash, p.recipient, p.amount);
            }
            return;
        }

        uint8 canonicalKind = _canonicalErc20Kind[_peerKey(p.peerChainId, p.peerToken)];
        if (canonicalKind != CANONICAL_NONE) {
            if (canonicalKind == CANONICAL_BUINT_ERC20) {
                if (buint == address(0)) revert BUintNotSet();
                IBeamioBUnitsBridge(buint).mintPaid(p.recipient, p.amount);
                emit PeerDepositExecuted(depositTxHash, buint, p.recipient, p.amount);
                emit MintExecuted(buint, p.recipient, p.amount);
                return;
            }
            if (canonicalKind == CANONICAL_GB_ERC20) {
                if (gbTokenErc20 == address(0)) revert GbTokenErc20NotSet();
                IGBTokenErc20Bridge(gbTokenErc20).mintPaid(p.recipient, p.amount);
                emit PeerDepositExecuted(depositTxHash, gbTokenErc20, p.recipient, p.amount);
                emit GBIssueExecuted(depositTxHash, p.recipient, p.amount);
                emit MintExecuted(gbTokenErc20, p.recipient, p.amount);
                return;
            }
            if (canonicalKind == CANONICAL_USDC_ERC20) {
                if (usdcErc20 == address(0)) revert UsdcErc20NotSet();
                IConetTreasuryFactoryMinter(treasury).mintFactoryToken(usdcErc20, p.recipient, p.amount);
                _replenishOutboundFromInboundUsdc(p.peerChainId, p.amount);
                emit PeerDepositExecuted(depositTxHash, usdcErc20, p.recipient, p.amount);
                emit MintExecuted(usdcErc20, p.recipient, p.amount);
                return;
            }
            if (canonicalKind == CANONICAL_WCNET_ERC20) {
                address w = _requireWrappedConet();
                IConetTreasuryFactoryMinter(treasury).mintFactoryToken(w, p.recipient, p.amount);
                emit PeerDepositExecuted(depositTxHash, w, p.recipient, p.amount);
                emit MintExecuted(w, p.recipient, p.amount);
                return;
            }
            revert InvalidCanonicalKind();
        }

        if (p.peerToken == BUINT_PEER_TOKEN) {
            if (buint == address(0)) revert BUintNotSet();
            IBeamioBUnitsBridge(buint).mintPaid(p.recipient, p.amount);
            emit PeerDepositExecuted(depositTxHash, buint, p.recipient, p.amount);
            emit MintExecuted(buint, p.recipient, p.amount);
            return;
        }

        if (p.peerToken == GB_PEER_TOKEN) {
            if (conetGB == address(0)) revert ConetGBNotSet();
            IConetGB1155(conetGB).issueGB(p.recipient, p.amount);
            emit PeerDepositExecuted(depositTxHash, conetGB, p.recipient, p.amount);
            emit GBIssueExecuted(depositTxHash, p.recipient, p.amount);
            return;
        }

        address wrapped = _ensureWrappedToken(p.peerChainId, p.peerToken);
        IConetTreasuryFactoryMinter(treasury).mintFactoryToken(wrapped, p.recipient, p.amount);
        emit PeerDepositExecuted(depositTxHash, wrapped, p.recipient, p.amount);
        emit MintExecuted(wrapped, p.recipient, p.amount);
    }

    function _stableKindToken(uint8 kind) internal view returns (address) {
        if (kind == CANONICAL_USDC_ERC20) return usdcErc20;
        if (kind == CANONICAL_GB_ERC20) return gbTokenErc20;
        if (kind == CANONICAL_BUINT_ERC20) return buint;
        revert InvalidCanonicalKind();
    }

    function getPeerDepositProposal(bytes32 depositTxHash)
        external
        view
        returns (
            uint256 peerChainId,
            address peerToken,
            address recipient,
            uint256 amount,
            uint8 creditAssetKind,
            uint256 voteCount,
            bool executed
        )
    {
        PeerDepositProposal storage p = peerDepositProposals[depositTxHash];
        return (p.peerChainId, p.peerToken, p.recipient, p.amount, p.creditAssetKind, p.voteCount, p.executed);
    }
}
