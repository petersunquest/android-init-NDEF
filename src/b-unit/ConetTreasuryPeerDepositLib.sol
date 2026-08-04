// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IConetTreasuryFactoryMinterDeposit {
    function mintFactoryToken(address token, address to, uint256 amount) external;
}

interface IBeamioBUnitsBridgeDeposit {
    function mintPaid(address to, uint256 amount) external;
}

interface IGBTokenErc20BridgeDeposit {
    function mintPaid(address to, uint256 amount) external;
}

/// @dev Legacy ConetGB1155.issueGB — Peer fallback only when gbTokenErc20 unset.
interface IConetGB1155Deposit {
    function issueGB(address to, uint256 amountGB18) external;
}

/// @dev Peer 入桥 mint 执行（外部 library，减轻 Peer EIP-170 体积）。
library ConetTreasuryPeerDepositLib {
    uint8 internal constant CANONICAL_NONE = 0;
    uint8 internal constant CANONICAL_GB_ERC20 = 1;
    uint8 internal constant CANONICAL_USDC_ERC20 = 2;
    uint8 internal constant CANONICAL_BUINT_ERC20 = 3;
    uint8 internal constant CANONICAL_WCNET_ERC20 = 4;

    address internal constant BUINT_PEER_TOKEN = 0x000000000000000000000000000000000000B001;
    address internal constant GB_PEER_TOKEN = 0x000000000000000000000000000000000000B002;

    error BUintNotSet();
    error ConetGBNotSet();
    error GbTokenErc20NotSet();
    error UsdcErc20NotSet();
    error InvalidCanonicalKind();
    error WrappedConetNotRegistered();

    event PeerDepositExecuted(bytes32 indexed depositTxHash, address indexed mintTarget, address recipient, uint256 amount);
    event MintExecuted(address indexed token, address indexed to, uint256 amount);
    event GBIssueExecuted(bytes32 indexed txHash, address to, uint256 amountGB18);

    /// @return mintTarget 实际 mint 的 token；usdcReplenishAmount>0 时 Peer 须 replenish outbound。
    function executeDepositMint(
        bytes32 depositTxHash,
        uint256 peerChainId,
        address peerToken,
        address recipient,
        uint256 amount,
        uint8 creditAssetKind,
        uint8 canonicalKind,
        address treasury,
        address usdcErc20,
        address gbTokenErc20,
        address buint,
        address wrappedConet,
        address conetGB,
        address wrappedTokenOrZero
    ) external returns (address mintTarget, uint256 usdcReplenishAmount) {
        if (creditAssetKind != 0) {
            mintTarget = _mintByStableKind(treasury, usdcErc20, gbTokenErc20, buint, creditAssetKind, recipient, amount);
            if (creditAssetKind == CANONICAL_USDC_ERC20) {
                usdcReplenishAmount = amount;
            }
            emit PeerDepositExecuted(depositTxHash, mintTarget, recipient, amount);
            if (creditAssetKind == CANONICAL_GB_ERC20) {
                emit GBIssueExecuted(depositTxHash, recipient, amount);
            }
            return (mintTarget, usdcReplenishAmount);
        }

        if (canonicalKind != CANONICAL_NONE) {
            if (canonicalKind == CANONICAL_BUINT_ERC20) {
                if (buint == address(0)) revert BUintNotSet();
                IBeamioBUnitsBridgeDeposit(buint).mintPaid(recipient, amount);
                emit PeerDepositExecuted(depositTxHash, buint, recipient, amount);
                emit MintExecuted(buint, recipient, amount);
                return (buint, 0);
            }
            if (canonicalKind == CANONICAL_GB_ERC20) {
                if (gbTokenErc20 == address(0)) revert GbTokenErc20NotSet();
                IGBTokenErc20BridgeDeposit(gbTokenErc20).mintPaid(recipient, amount);
                emit PeerDepositExecuted(depositTxHash, gbTokenErc20, recipient, amount);
                emit GBIssueExecuted(depositTxHash, recipient, amount);
                emit MintExecuted(gbTokenErc20, recipient, amount);
                return (gbTokenErc20, 0);
            }
            if (canonicalKind == CANONICAL_USDC_ERC20) {
                if (usdcErc20 == address(0)) revert UsdcErc20NotSet();
                IConetTreasuryFactoryMinterDeposit(treasury).mintFactoryToken(usdcErc20, recipient, amount);
                emit PeerDepositExecuted(depositTxHash, usdcErc20, recipient, amount);
                emit MintExecuted(usdcErc20, recipient, amount);
                return (usdcErc20, amount);
            }
            if (canonicalKind == CANONICAL_WCNET_ERC20) {
                if (wrappedConet == address(0)) revert WrappedConetNotRegistered();
                IConetTreasuryFactoryMinterDeposit(treasury).mintFactoryToken(wrappedConet, recipient, amount);
                emit PeerDepositExecuted(depositTxHash, wrappedConet, recipient, amount);
                emit MintExecuted(wrappedConet, recipient, amount);
                return (wrappedConet, 0);
            }
            revert InvalidCanonicalKind();
        }

        if (peerToken == BUINT_PEER_TOKEN) {
            if (buint == address(0)) revert BUintNotSet();
            IBeamioBUnitsBridgeDeposit(buint).mintPaid(recipient, amount);
            emit PeerDepositExecuted(depositTxHash, buint, recipient, amount);
            emit MintExecuted(buint, recipient, amount);
            return (buint, 0);
        }

        if (peerToken == GB_PEER_TOKEN) {
            if (conetGB == address(0)) revert ConetGBNotSet();
            IConetGB1155Deposit(conetGB).issueGB(recipient, amount);
            emit PeerDepositExecuted(depositTxHash, conetGB, recipient, amount);
            emit GBIssueExecuted(depositTxHash, recipient, amount);
            return (conetGB, 0);
        }

        // wrappedTokenOrZero 须由 Peer `_ensureWrappedToken` 预先解析
        address wrapped = wrappedTokenOrZero;
        IConetTreasuryFactoryMinterDeposit(treasury).mintFactoryToken(wrapped, recipient, amount);
        emit PeerDepositExecuted(depositTxHash, wrapped, recipient, amount);
        emit MintExecuted(wrapped, recipient, amount);
        return (wrapped, 0);
    }

    function _mintByStableKind(
        address treasury,
        address usdcErc20,
        address gbTokenErc20,
        address buint,
        uint8 kind,
        address recipient,
        uint256 amount
    ) private returns (address tokenMinted) {
        if (kind == CANONICAL_USDC_ERC20) {
            if (usdcErc20 == address(0)) revert UsdcErc20NotSet();
            IConetTreasuryFactoryMinterDeposit(treasury).mintFactoryToken(usdcErc20, recipient, amount);
            emit MintExecuted(usdcErc20, recipient, amount);
            return usdcErc20;
        }
        if (kind == CANONICAL_GB_ERC20) {
            if (gbTokenErc20 == address(0)) revert GbTokenErc20NotSet();
            IGBTokenErc20BridgeDeposit(gbTokenErc20).mintPaid(recipient, amount);
            emit MintExecuted(gbTokenErc20, recipient, amount);
            return gbTokenErc20;
        }
        if (kind == CANONICAL_BUINT_ERC20) {
            if (buint == address(0)) revert BUintNotSet();
            IBeamioBUnitsBridgeDeposit(buint).mintPaid(recipient, amount);
            emit MintExecuted(buint, recipient, amount);
            return buint;
        }
        revert InvalidCanonicalKind();
    }
}
