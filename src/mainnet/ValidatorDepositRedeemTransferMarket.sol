// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "../contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "../contracts/utils/cryptography/ECDSA.sol";

/// @dev EIP-3009 (bytes signature) — CoNET-USDC / FactoryERC20 gasless authorized transfer.
interface IERC3009BytesSig {
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}

/// @dev Host callbacks for node ownership transfer during order fulfilment.
interface IValidatorDepositRedeemHost {
    function beneficiaryNonces(address account) external view returns (uint256);

    function consumeBeneficiaryNonceForMarket(address account, uint256 nonce) external;

    function nodeWalletBeneficiary(address nodeWallet) external view returns (address);

    function usdcTokenAddress() external view returns (address);

    function transferOneNodeWalletForMarket(address from, address to, address nodeWallet) external;
}

/**
 * @title ValidatorDepositRedeemTransferMarket
 * @notice Transfer-order marketplace for ValidatorDepositRedeem (EIP-712 + EIP-3009 fulfil).
 * @dev Kept separate so the main redeem contract stays within EIP-170. Uses the same EIP-712
 *      domain name/version as the host so type hashes match; only {verifyingContract} differs.
 */
contract ValidatorDepositRedeemTransferMarket is EIP712 {
    IValidatorDepositRedeemHost public immutable redeemHost;

    struct TransferOrder {
        address seller;
        uint256 priceUsdc6;
        address buyer;
        uint64 createdAt;
        uint64 filledAt;
        bool active;
    }

    mapping(uint256 => TransferOrder) private _orders;
    mapping(uint256 => address[]) private _orderNodes;
    mapping(address => uint256) public nodeOrder;
    uint256 public nextOrderId;

    bytes32 private constant CREATE_TRANSFER_ORDER_TYPEHASH = keccak256(
        "CreateTransferOrder(address seller,address[] nodeWallets,uint256 priceUsdc6,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant CANCEL_TRANSFER_ORDER_TYPEHASH = keccak256(
        "CancelTransferOrder(address seller,uint256 orderId,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant FULFILL_TRANSFER_ORDER_TYPEHASH = keccak256(
        "FulfillTransferOrder(address buyer,uint256 orderId,uint256 nonce,uint256 deadline)"
    );

    event TransferOrderCreated(uint256 indexed orderId, address indexed seller, uint256 priceUsdc6, address[] nodeWallets);
    event TransferOrderCancelled(uint256 indexed orderId, address indexed seller);
    event TransferOrderFilled(uint256 indexed orderId, address indexed seller, address indexed buyer, uint256 priceUsdc6);

    constructor(address redeemHost_) EIP712("ValidatorDepositRedeem", "1") {
        require(redeemHost_ != address(0), "TransferMarket: zero host");
        redeemHost = IValidatorDepositRedeemHost(redeemHost_);
    }

    function createTransferOrder(
        address seller,
        address[] calldata nodeWallets,
        uint256 priceUsdc6,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external returns (uint256 orderId) {
        require(block.timestamp <= deadline, "TransferMarket: expired");
        require(nodeWallets.length > 0, "TransferMarket: empty");
        require(priceUsdc6 > 0, "TransferMarket: zero price");
        require(redeemHost.beneficiaryNonces(seller) == nonce, "TransferMarket: bad nonce");

        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_TRANSFER_ORDER_TYPEHASH,
                seller,
                _hashAddressArray(nodeWallets),
                priceUsdc6,
                nonce,
                deadline
            )
        );
        require(ECDSA.recover(_hashTypedDataV4(structHash), signature) == seller, "TransferMarket: bad sig");
        redeemHost.consumeBeneficiaryNonceForMarket(seller, nonce);

        orderId = ++nextOrderId;
        for (uint256 i = 0; i < nodeWallets.length; i++) {
            address nodeWallet = nodeWallets[i];
            require(nodeWallet != address(0), "TransferMarket: zero node wallet");
            require(redeemHost.nodeWalletBeneficiary(nodeWallet) == seller, "TransferMarket: not seller node");
            require(nodeOrder[nodeWallet] == 0, "TransferMarket: node already listed");
            nodeOrder[nodeWallet] = orderId;
            _orderNodes[orderId].push(nodeWallet);
        }
        _orders[orderId] = TransferOrder({
            seller: seller,
            priceUsdc6: priceUsdc6,
            buyer: address(0),
            createdAt: uint64(block.timestamp),
            filledAt: 0,
            active: true
        });
        emit TransferOrderCreated(orderId, seller, priceUsdc6, nodeWallets);
    }

    function cancelTransferOrder(
        uint256 orderId,
        address seller,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "TransferMarket: expired");
        TransferOrder storage o = _orders[orderId];
        require(o.active, "TransferMarket: order not active");
        require(o.seller == seller, "TransferMarket: not seller");
        require(redeemHost.beneficiaryNonces(seller) == nonce, "TransferMarket: bad nonce");

        bytes32 structHash = keccak256(
            abi.encode(CANCEL_TRANSFER_ORDER_TYPEHASH, seller, orderId, nonce, deadline)
        );
        require(ECDSA.recover(_hashTypedDataV4(structHash), signature) == seller, "TransferMarket: bad sig");
        redeemHost.consumeBeneficiaryNonceForMarket(seller, nonce);

        _unlockOrderNodes(orderId);
        o.active = false;
        emit TransferOrderCancelled(orderId, seller);
    }

    function fulfillTransferOrder(
        uint256 orderId,
        address buyer,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature,
        uint256 payValidAfter,
        uint256 payValidBefore,
        bytes32 payNonce,
        bytes calldata paySignature
    ) external {
        require(block.timestamp <= deadline, "TransferMarket: expired");
        require(buyer != address(0), "TransferMarket: zero buyer");
        TransferOrder storage o = _orders[orderId];
        require(o.active, "TransferMarket: order not active");
        require(buyer != o.seller, "TransferMarket: buyer is seller");
        require(redeemHost.beneficiaryNonces(buyer) == nonce, "TransferMarket: bad nonce");
        address usdcAddr = redeemHost.usdcTokenAddress();
        require(usdcAddr != address(0), "TransferMarket: usdc unset");

        bytes32 structHash = keccak256(
            abi.encode(FULFILL_TRANSFER_ORDER_TYPEHASH, buyer, orderId, nonce, deadline)
        );
        require(ECDSA.recover(_hashTypedDataV4(structHash), signature) == buyer, "TransferMarket: bad sig");
        redeemHost.consumeBeneficiaryNonceForMarket(buyer, nonce);

        IERC3009BytesSig(usdcAddr).transferWithAuthorization(
            buyer,
            o.seller,
            o.priceUsdc6,
            payValidAfter,
            payValidBefore,
            payNonce,
            paySignature
        );

        address[] storage nodes = _orderNodes[orderId];
        for (uint256 i = 0; i < nodes.length; i++) {
            address nodeWallet = nodes[i];
            nodeOrder[nodeWallet] = 0;
            require(redeemHost.nodeWalletBeneficiary(nodeWallet) == o.seller, "TransferMarket: node moved");
            redeemHost.transferOneNodeWalletForMarket(o.seller, buyer, nodeWallet);
        }

        o.active = false;
        o.buyer = buyer;
        o.filledAt = uint64(block.timestamp);
        emit TransferOrderFilled(orderId, o.seller, buyer, o.priceUsdc6);
    }

    function getTransferOrder(uint256 orderId)
        external
        view
        returns (
            address seller,
            address[] memory nodeWallets,
            uint256 priceUsdc6,
            bool active,
            address buyer,
            uint64 createdAt,
            uint64 filledAt
        )
    {
        TransferOrder storage o = _orders[orderId];
        return (o.seller, _orderNodes[orderId], o.priceUsdc6, o.active, o.buyer, o.createdAt, o.filledAt);
    }

    function getCreateTransferOrderDigest(
        address seller,
        address[] calldata nodeWallets,
        uint256 priceUsdc6,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(CREATE_TRANSFER_ORDER_TYPEHASH, seller, _hashAddressArray(nodeWallets), priceUsdc6, nonce, deadline)
        );
        return _hashTypedDataV4(structHash);
    }

    function getCancelTransferOrderDigest(
        uint256 orderId,
        address seller,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(CANCEL_TRANSFER_ORDER_TYPEHASH, seller, orderId, nonce, deadline));
        return _hashTypedDataV4(structHash);
    }

    function getFulfillTransferOrderDigest(
        uint256 orderId,
        address buyer,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(FULFILL_TRANSFER_ORDER_TYPEHASH, buyer, orderId, nonce, deadline));
        return _hashTypedDataV4(structHash);
    }

    function _unlockOrderNodes(uint256 orderId) internal {
        address[] storage nodes = _orderNodes[orderId];
        for (uint256 i = 0; i < nodes.length; i++) {
            if (nodeOrder[nodes[i]] == orderId) {
                nodeOrder[nodes[i]] = 0;
            }
        }
    }

    function _hashAddressArray(address[] calldata arr) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](arr.length);
        for (uint256 i = 0; i < arr.length; i++) {
            h[i] = bytes32(uint256(uint160(arr[i])));
        }
        return keccak256(abi.encodePacked(h));
    }
}
