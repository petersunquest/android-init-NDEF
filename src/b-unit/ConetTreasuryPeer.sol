// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FactoryERC20} from "./FactoryERC20.sol";

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
}

/**
 * @title ConetTreasuryPeer
 * @dev 跨链 peer 桥模块（各链 Nick CREATE2 同址；constructor 固定 Treasury 同址）。
 *      Relayer 监听源链 BridgeOut 事件，在目标链对本合约 voteMintFromPeerDeposit。
 *      包装 ERC20 minter 为 Treasury；本模块经 mintFactoryToken / burnFactoryFrom 代操作。
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
        uint256 voteCount;
        bool executed;
    }
    mapping(bytes32 => PeerDepositProposal) public peerDepositProposals;
    mapping(bytes32 => mapping(address => bool)) public hasVotedPeerDeposit;

    address public wrappedConet;
    address public buint;
    address public conetGB;

    uint256 public constant CONET_CHAIN_ID = 224422;
    address public constant NATIVE_PEER_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public constant BUINT_PEER_TOKEN = 0x000000000000000000000000000000000000B001;
    address public constant GB_PEER_TOKEN = 0x000000000000000000000000000000000000B002;
    address private constant NICK_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

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
    event PeerCanonicalAssetRegistered(uint256 indexed peerChainId, address indexed peerToken, string assetLabel);
    event GBIssueExecuted(bytes32 indexed txHash, address to, uint256 amountGB18);

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
    error NotConetChain();
    error TransferFailed();
    error WrappedTokenNotTracked();

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

    function _wrappedSalt(uint256 peerChainId, address peerToken) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("beamio.wrapped.erc20.v1", peerChainId, peerToken));
    }

    function _predictCreate2(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), NICK_CREATE2_FACTORY, salt, initCodeHash));
        return address(uint160(uint256(hash)));
    }

    function _nickCreate2Deploy(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        deployed = _predictCreate2(salt, keccak256(initCode));
        (bool ok,) = NICK_CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        if (!ok) revert WrappedDeployFailed();
        uint256 size;
        assembly {
            size := extcodesize(deployed)
        }
        if (size == 0) revert WrappedDeployFailed();
    }

    function _factoryInitCode(string memory name_, string memory symbol_, uint8 decimals_)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(type(FactoryERC20).creationCode, abi.encode(name_, symbol_, decimals_, treasury));
    }

    function _computeWrappedAddress(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 peerChainId,
        address peerToken
    ) internal view returns (address) {
        bytes memory initCode = _factoryInitCode(name_, symbol_, decimals_);
        return _predictCreate2(_wrappedSalt(peerChainId, peerToken), keccak256(initCode));
    }

    function registerPeerToken(
        uint256 peerChainId,
        address peerToken,
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_
    ) external onlyMiner returns (address predicted) {
        if (peerToken == address(0)) revert InvalidTarget();
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

        wrapped = _computeWrappedAddress(meta.name, meta.symbol, meta.decimals, peerChainId, peerToken);
        uint256 size;
        assembly {
            size := extcodesize(wrapped)
        }
        if (size > 0) {
            _trackWrappedToken(wrapped, peerChainId, peerToken);
            return wrapped;
        }

        bytes memory initCode = _factoryInitCode(meta.name, meta.symbol, meta.decimals);
        bytes32 salt = _wrappedSalt(peerChainId, peerToken);
        address deployed = _nickCreate2Deploy(salt, initCode);
        if (deployed != wrapped) revert WrappedAddressMismatch();

        assembly {
            size := extcodesize(wrapped)
        }
        if (size == 0) revert WrappedDeployFailed();

        _trackWrappedToken(wrapped, peerChainId, peerToken);
        emit WrappedTokenDeployed(peerChainId, peerToken, wrapped);
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
        if (block.chainid == CONET_CHAIN_ID) {
            wrappedConet = token;
        }
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
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidTarget();
        if (destinationChainId == block.chainid) revert InvalidTarget();
        address w = _requireWrappedConet();
        if (!_isWrappedToken[w]) revert WrappedTokenNotTracked();
        IConetTreasuryFactoryMinter(treasury).burnFactoryFrom(w, msg.sender, amount);
        emit WrappedConetBridgeOut(msg.sender, amount, destinationChainId, recipient);
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
        if (amount == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidTarget();
        if (destinationChainId == block.chainid) revert InvalidTarget();
        if (buint == address(0)) revert BUintNotSet();
        IBeamioBUnitsBridge(buint).consumeFuel(msg.sender, amount);
        emit BUintBridgeOut(msg.sender, amount, destinationChainId, recipient);
    }

    function burnGBForBridge(uint256 amountGB18, uint256 destinationChainId, address recipient) external {
        if (amountGB18 == 0) revert InvalidAmount();
        if (recipient == address(0)) revert InvalidTarget();
        if (destinationChainId == block.chainid) revert InvalidTarget();
        if (conetGB == address(0)) revert ConetGBNotSet();
        IConetGB1155(conetGB).revokeTotalOnly(msg.sender, amountGB18);
        emit GBBridgeOut(msg.sender, amountGB18, destinationChainId, recipient);
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
        _applyPeerDepositVote(msg.sender, depositTxHash, peerChainId, peerToken, recipient, amount);
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
        uint256 amount
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
            p.voteCount = 1;
            emit PeerDepositProposalCreated(depositTxHash, peerChainId, peerToken, recipient, amount, miner);
        } else {
            if (
                p.peerChainId != peerChainId || p.peerToken != peerToken || p.recipient != recipient || p.amount != amount
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

    function getPeerDepositProposal(bytes32 depositTxHash)
        external
        view
        returns (
            uint256 peerChainId,
            address peerToken,
            address recipient,
            uint256 amount,
            uint256 voteCount,
            bool executed
        )
    {
        PeerDepositProposal storage p = peerDepositProposals[depositTxHash];
        return (p.peerChainId, p.peerToken, p.recipient, p.amount, p.voteCount, p.executed);
    }
}
