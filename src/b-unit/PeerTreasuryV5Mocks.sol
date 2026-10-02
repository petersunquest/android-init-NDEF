// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @dev 本地测试用。生产出金读的是 TreasuryCanonicalERC20V3 与 TreasuryBridgeV3。
contract PeerV5MockUsdc {
    string public constant name = "CoNET USD Coin";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;
    address public burner;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(address burner_) { burner = burner_; }

    function setBurner(address burner_) external { burner = burner_; }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 current = allowance[from][msg.sender];
        require(current >= value, "allowance");
        unchecked { allowance[from][msg.sender] = current - value; }
        _transfer(from, to, value);
        return true;
    }

    function burnFrom(address account, uint256 amount) external {
        require(msg.sender == burner, "burner");
        require(balanceOf[account] >= amount, "balance");
        unchecked { balanceOf[account] -= amount; }
        emit Transfer(account, address(0), amount);
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        require(block.timestamp > validAfter && block.timestamp < validBefore, "window");
        require(!authorizationState[from][nonce], "used");
        bytes32 structHash = keccak256(abi.encode(
            keccak256("TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"),
            from, to, value, validAfter, validBefore, nonce
        ));
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
        address signer = ECDSA.recover(MessageHashUtils.toTypedDataHash(domain, structHash), signature);
        require(signer == from, "sig");
        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(balanceOf[from] >= value, "balance");
        unchecked {
            balanceOf[from] -= value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }
}

contract PeerV5MockGb {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public admin;

    constructor(address admin_) { admin = admin_; }

    function mintPaid(address to, uint256 amount) external {
        require(msg.sender == admin, "admin");
        balanceOf[to] += amount;
    }

    function faucet(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "balance");
        unchecked {
            balanceOf[msg.sender] -= value;
            balanceOf[to] += value;
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (msg.sender != from) {
            uint256 current = allowance[from][msg.sender];
            require(current >= value, "allowance");
            unchecked { allowance[from][msg.sender] = current - value; }
        }
        require(balanceOf[from] >= value, "balance");
        unchecked {
            balanceOf[from] -= value;
            balanceOf[to] += value;
        }
        return true;
    }

    function burnFrom(address account, uint256 amount) external {
        uint256 current = allowance[account][msg.sender];
        require(current >= amount, "allowance");
        unchecked { allowance[account][msg.sender] = current - amount; }
        require(balanceOf[account] >= amount, "balance");
        unchecked { balanceOf[account] -= amount; }
    }
}

contract PeerV5MockBridge {
    uint256 public feeBps;
    address public usdc;
    bytes32 public lastOp;
    address public lastSource;
    uint256 public lastDestChain;
    address public lastDestAsset;
    uint256 public lastPrincipal;

    constructor(address usdc_, uint256 feeBps_) {
        usdc = usdc_;
        feeBps = feeBps_;
    }

    function destinationFeeBps(uint256) external view returns (uint256) { return feeBps; }

    function initiateBurnRelease(
        address sourceAsset,
        uint256 destinationChainId,
        address destinationAsset,
        address[] calldata,
        uint256[] calldata amounts,
        bytes32,
        uint256
    ) external returns (bytes32 operationId) {
        uint256 principal;
        for (uint256 i = 0; i < amounts.length; i++) principal += amounts[i];
        uint256 fee = principal * feeBps / 10_000;
        if (fee > 0) {
            require(PeerV5MockUsdc(usdc).transferFrom(msg.sender, address(this), fee), "fee");
        }
        PeerV5MockUsdc(usdc).burnFrom(msg.sender, principal);
        lastOp = keccak256(abi.encode(sourceAsset, destinationChainId, destinationAsset, principal, msg.sender));
        lastSource = sourceAsset;
        lastDestChain = destinationChainId;
        lastDestAsset = destinationAsset;
        lastPrincipal = principal;
        return lastOp;
    }
}

contract PeerV5MockGuardians {
    mapping(uint256 => address) public idOwner;
    function setOwner(uint256 id, address owner) external { idOwner[id] = owner; }
}
