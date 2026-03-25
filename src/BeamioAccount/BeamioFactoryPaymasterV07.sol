// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// BeamioFactoryPaymasterV07.sol
// - Deploy + init BeamioAccount (Route A)
// - Paymaster v0.7 (simple allow-list for BeamioAccount senders)
// - Relay entrypoints to BeamioAccount (paymaster pays gas)
// - Provides GLOBAL config views for module logic: containerModule / quoteHelper / beamioUserCard / USDC

import "./BeamioTypesV07.sol";
import "./BeamioContainerItemTypesV07.sol";
import "./BeamioAccountDeployer.sol";
import "./BeamioAccount.sol"; // provides IBeamioAccountFactoryConfigV2
import "../contracts/utils/cryptography/ECDSA.sol";
import "../contracts/utils/cryptography/MessageHashUtils.sol";

contract BeamioFactoryPaymasterV07 is IPaymasterV07, IBeamioAccountFactoryConfigV2 {
	IEntryPointV07 public constant ENTRY_POINT =
		IEntryPointV07(0x0000000071727De22E5E9d8BAf0edAc6f37da032);

	BeamioAccountDeployer public deployer;

	// ========= registry =========
	mapping(address => bool) public isBeamioAccount;

	address public admin;

	mapping(address => uint256) public nextIndexOfCreator;
	mapping(address => address) public primaryAccountOf;
	mapping(address => address[]) internal accountsByCreator;

	address[] public payMasters;
	mapping(address => bool) public isPayMaster;

	uint256 public accountLimit;

	// Owner-signed execute: nonce replay protection（通用 executeForOwner）
	mapping(bytes32 => bool) public usedOwnerExecuteNonces;

	// Redeemer/claimer-signed execute: nonce replay protection（redeem / faucetRedeemPool）
	mapping(bytes32 => bool) public usedRedeemerExecuteNonces;

	// ========= GLOBAL module/config =========
	address public override containerModule;
	address public override quoteHelper;
	address public override beamioUserCard;
	address public override USDC;

	/// @dev Trusted contract: only BeamioAccount may call into it; it forwards mintPointsOpenContainerRelay on UserCard.
	address private _openContainerMintExecutor;

	// ========= errors =========
	error RedeemerSignerMismatch(address signer, address expected);
	error RedeemerToMustEqualClaimer();

	// ========= events =========
	event AccountCreated(address indexed creator, address indexed account, uint256 index, bytes32 salt);
	event DeployerUpdated(address indexed oldDeployer, address indexed newDeployer);

	event ModuleUpdated(address indexed oldModule, address indexed newModule);
	event QuoteHelperUpdated(address indexed oldHelper, address indexed newHelper);
	event UserCardUpdated(address indexed oldCard, address indexed newCard);
	event USDCUpdated(address indexed oldUSDC, address indexed newUSDC);
	event OpenContainerMintExecutorUpdated(address indexed oldExecutor, address indexed newExecutor);

	modifier onlyAdmin() {
		require(msg.sender == admin, "not admin");
		_;
	}

	modifier onlyPayMaster() {
		require(isPayMaster[msg.sender], "not payMaster");
		_;
	}

	modifier onlyEntryPoint() {
		require(msg.sender == address(ENTRY_POINT), "only entryPoint");
		_;
	}

	constructor(
		uint256 initialAccountLimit,
		address deployer_,
		address module_,
		address quoteHelper_,
		address userCard_,
		address usdc_
	) {
		require(initialAccountLimit > 0, "limit=0");
		require(deployer_ != address(0) && deployer_.code.length > 0, "bad deployer");
		require(module_ != address(0) && module_.code.length > 0, "bad module");
		require(quoteHelper_ != address(0) && quoteHelper_.code.length > 0, "bad helper");
		require(userCard_ != address(0) && userCard_.code.length > 0, "bad userCard");
		require(usdc_ != address(0), "bad usdc");

		admin = msg.sender;
		accountLimit = initialAccountLimit;

		isPayMaster[msg.sender] = true;
		payMasters.push(msg.sender);

		deployer = BeamioAccountDeployer(deployer_);
		emit DeployerUpdated(address(0), deployer_);
		try deployer.setFactory(address(this)) {} catch {}

		containerModule = module_;
		quoteHelper = quoteHelper_;
		beamioUserCard = userCard_;
		USDC = usdc_;
		emit ModuleUpdated(address(0), module_);
		emit QuoteHelperUpdated(address(0), quoteHelper_);
		emit UserCardUpdated(address(0), userCard_);
		emit USDCUpdated(address(0), usdc_);

		DOMAIN_SEPARATOR = keccak256(abi.encode(
			keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
			keccak256(bytes("BeamioAccountFactory")),
			keccak256(bytes("1")),
			block.chainid,
			address(this)
		));
	}

	bytes32 public constant EXECUTE_FOR_OWNER_TYPEHASH = keccak256(
		"ExecuteForOwner(address account,bytes32 dataHash,uint256 deadline,bytes32 nonce)"
	);

	bytes32 public constant EXECUTE_FOR_REDEEMER_TYPEHASH = keccak256(
		"ExecuteForRedeemer(address account,bytes32 dataHash,uint256 deadline,bytes32 nonce)"
	);

	bytes32 public immutable DOMAIN_SEPARATOR;

	// =========================================================
	// Admin ops
	// =========================================================
	function transferAdmin(address newAdmin) external onlyAdmin {
		require(newAdmin != address(0), "zero admin");
		admin = newAdmin;
	}

	function setAccountLimit(uint256 newLimit) external onlyAdmin {
		require(newLimit > 0 && newLimit <= 10000, "bad limit");
		accountLimit = newLimit;
	}

	function updateDeployer(address newDeployer) external onlyAdmin {
		require(newDeployer != address(0) && newDeployer.code.length > 0, "bad deployer");
		emit DeployerUpdated(address(deployer), newDeployer);
		deployer = BeamioAccountDeployer(newDeployer);
		try deployer.setFactory(address(this)) {} catch {}
	}

	function setModule(address newModule) external onlyAdmin {
		require(newModule != address(0) && newModule.code.length > 0, "bad module");
		emit ModuleUpdated(containerModule, newModule);
		containerModule = newModule;
	}

	function setQuoteHelper(address newHelper) external onlyAdmin {
		require(newHelper != address(0) && newHelper.code.length > 0, "bad helper");
		emit QuoteHelperUpdated(quoteHelper, newHelper);
		quoteHelper = newHelper;
	}

	function setUserCard(address newCard) external onlyAdmin {
		require(newCard != address(0) && newCard.code.length > 0, "bad card");
		emit UserCardUpdated(beamioUserCard, newCard);
		beamioUserCard = newCard;
	}

	function setUSDC(address newUSDC) external onlyAdmin {
		require(newUSDC != address(0), "bad usdc");
		emit USDCUpdated(USDC, newUSDC);
		USDC = newUSDC;
	}

	function openContainerMintExecutor() external view override returns (address) {
		return _openContainerMintExecutor;
	}

	function setOpenContainerMintExecutor(address exec) external onlyAdmin {
		emit OpenContainerMintExecutorUpdated(_openContainerMintExecutor, exec);
		_openContainerMintExecutor = exec;
	}

	function getPayMasters() external view returns (address[] memory) {
		return payMasters;
	}

	function addPayMaster(address pm) external onlyAdmin {
		require(pm != address(0), "zero pm");
		require(!isPayMaster[pm], "already pm");
		isPayMaster[pm] = true;
		payMasters.push(pm);
	}

	function removePayMaster(address pm) external onlyAdmin {
		require(isPayMaster[pm], "not pm");
		require(payMasters.length > 1, "last pm");

		isPayMaster[pm] = false;

		uint256 len = payMasters.length;
		for (uint256 i = 0; i < len; i++) {
			if (payMasters[i] == pm) {
				payMasters[i] = payMasters[len - 1];
				payMasters.pop();
				break;
			}
		}
	}

	// =========================================================
	// Entrypoint deposit/withdraw
	// =========================================================
	function deposit() external payable onlyPayMaster {
		ENTRY_POINT.depositTo{value: msg.value}(address(this));
	}

	function withdrawTo(address payable to, uint256 amount) external onlyAdmin {
		ENTRY_POINT.withdrawTo(to, amount);
	}

	// =========================================================
	// Deterministic address
	// =========================================================
	function computeSalt(address creator, uint256 index) public pure returns (bytes32) {
		return keccak256(abi.encode(creator, index));
	}

	function _initCode() internal pure returns (bytes memory) {
		return abi.encodePacked(type(BeamioAccount).creationCode, abi.encode(ENTRY_POINT));
	}

	function getAddress(address creator, uint256 index) public view returns (address) {
		bytes32 salt = computeSalt(creator, index);
		bytes32 initCodeHash = keccak256(_initCode());
		bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(deployer), salt, initCodeHash));
		return address(uint160(uint256(hash)));
	}

	function beamioAccountOf(address creator) external view returns (address) {
		return primaryAccountOf[creator];
	}

	function myBeamioAccounts() external view returns (address[] memory) {
		return accountsByCreator[msg.sender];
	}

	// =========================================================
	// Create account (EOA)
	// =========================================================
	function createAccount() external returns (address account) {
		address creator = msg.sender;
		uint256 index = nextIndexOfCreator[creator];
		require(index < accountLimit, "limit");

		account = getAddress(creator, index);
		nextIndexOfCreator[creator] = index + 1;

		if (account.code.length > 0) {
			if (!isBeamioAccount[account]) {
				isBeamioAccount[account] = true;
				accountsByCreator[creator].push(account);
			}
			if (primaryAccountOf[creator] == address(0)) primaryAccountOf[creator] = account;
			return account;
		}

		bytes32 salt = computeSalt(creator, index);
		account = deployer.deploy(salt, _initCode());

		address[] memory managers = new address[](1);
		managers[0] = creator;

		// ⚠️ 这里假设你已把 BeamioAccount.initialize 改成不再接收 module
		BeamioAccount(payable(account)).initialize(creator, managers, 1, address(this));

		isBeamioAccount[account] = true;
		accountsByCreator[creator].push(account);
		if (primaryAccountOf[creator] == address(0)) primaryAccountOf[creator] = account;

		emit AccountCreated(creator, account, index, salt);
		return account;
	}

	// =========================================================
	// Create account for (paymaster)
	// =========================================================
	function createAccountFor(address creator) external onlyPayMaster returns (address account) {
		require(creator != address(0), "zero creator");

		uint256 index = nextIndexOfCreator[creator];
		require(index < accountLimit, "limit");

		account = getAddress(creator, index);
		nextIndexOfCreator[creator] = index + 1;

		if (account.code.length > 0) {
			if (!isBeamioAccount[account]) {
				isBeamioAccount[account] = true;
				accountsByCreator[creator].push(account);
			}
			if (primaryAccountOf[creator] == address(0)) primaryAccountOf[creator] = account;
			return account;
		}

		bytes32 salt = computeSalt(creator, index);
		account = deployer.deploy(salt, _initCode());

		address[] memory managers = new address[](1);
		managers[0] = creator;

		BeamioAccount(payable(account)).initialize(creator, managers, 1, address(this));

		isBeamioAccount[account] = true;
		accountsByCreator[creator].push(account);
		if (primaryAccountOf[creator] == address(0)) primaryAccountOf[creator] = account;

		emit AccountCreated(creator, account, index, salt);
		return account;
	}

	// =========================================================
	// Paymaster (AA v0.7)
	// =========================================================
	function validatePaymasterUserOp(
		PackedUserOperation calldata userOp,
		bytes32,
		uint256
	) external override view onlyEntryPoint returns (bytes memory context, uint256 validationData) {
		if (!isBeamioAccount[userOp.sender]) return ("", 1);
		return ("", 0);
	}

	function postOp(PostOpMode, bytes calldata, uint256, uint256) external override onlyEntryPoint {
		// no-op
	}

	// =========================================================
	// Relay entrypoints (factory pays gas)
	// =========================================================

	function relayContainerMainRelayed(
		address account,
		address to,
		ContainerItem[] calldata items,
		uint256 nonce_,
		uint256 deadline_,
		bytes calldata sig
	) external onlyPayMaster {
		require(isBeamioAccount[account], "not beamio account");
		BeamioAccount(payable(account)).containerMainRelayed(to, items, nonce_, deadline_, sig);
	}

	// ✅ token 参数已移除（与你最新 containerMainRelayedOpen 对齐）
	function relayContainerMainRelayedOpen(
		address account,
		address to,
		ContainerItem[] calldata items,
		uint8 currencyType,
		uint256 maxAmount,
		uint256 nonce_,
		uint256 deadline_,
		bytes calldata sig
	) external onlyPayMaster {
		require(isBeamioAccount[account], "not beamio account");
		BeamioAccount(payable(account)).containerMainRelayedOpen(
			to, items, currencyType, maxAmount, nonce_, deadline_, sig
		);
	}

	function relayContainerMainRelayedOpenUsdcTopupThenPoints(
		address account,
		address pointsTo,
		ContainerItem[] calldata items,
		uint8 currencyType,
		uint256 maxAmount,
		uint256 nonce_,
		uint256 deadline_,
		bytes calldata sig
	) external onlyPayMaster {
		require(isBeamioAccount[account], "not beamio account");
		BeamioAccount(payable(account)).containerMainRelayedOpenUsdcTopupThenPoints(
			pointsTo, items, currencyType, maxAmount, nonce_, deadline_, sig
		);
	}

	// ✅ token 参数已移除
	function simulateRelayOpen(
		address account,
		address to,
		ContainerItem[] calldata items,
		uint8 currencyType,
		uint256 maxAmount,
		uint256 nonce_,
		uint256 deadline_,
		bytes calldata sig
	) external view returns (bool ok, string memory reason) {
		if (!isBeamioAccount[account]) return (false, "not beamio account");
		return BeamioAccount(payable(account)).simulateOpenContainer(
			to, items, currencyType, maxAmount, nonce_, deadline_, sig
		);
	}

	function simulateRelayOpenUsdcTopupThenPoints(
		address account,
		address pointsTo,
		ContainerItem[] calldata items,
		uint8 currencyType,
		uint256 maxAmount,
		uint256 nonce_,
		uint256 deadline_,
		bytes calldata sig
	) external view returns (bool ok, string memory reason) {
		if (!isBeamioAccount[account]) return (false, "not beamio account");
		return BeamioAccount(payable(account)).simulateOpenContainerUsdcTopupThenPoints(
			pointsTo, items, currencyType, maxAmount, nonce_, deadline_, sig
		);
	}

	// ===== Redeem relays =====
	function relayCreateRedeem(
		address account,
		bytes32 passwordHash,
		address to,
		ContainerItem[] calldata items,
		uint64 expiry
	) external onlyPayMaster {
		require(isBeamioAccount[account], "not beamio account");
		BeamioAccount(payable(account)).createRedeem(passwordHash, to, items, expiry);
	}

	function relayCancelRedeem(address account, string calldata code) external onlyPayMaster {
		require(isBeamioAccount[account], "not beamio account");
		BeamioAccount(payable(account)).cancelRedeem(code);
	}

	function relayRedeem(address account, string calldata password, address to) external onlyPayMaster {
		require(isBeamioAccount[account], "not beamio account");
		BeamioAccount(payable(account)).redeem(password, to);
	}

	// ===== Faucet pool relays =====
	function relayCreateFaucetPool(
		address account,
		bytes32 passwordHash,
		uint32 totalCount,
		uint64 expiry,
		ContainerItem[] calldata items
	) external onlyPayMaster {
		require(isBeamioAccount[account], "not beamio account");
		BeamioAccount(payable(account)).createFaucetPool(passwordHash, totalCount, expiry, items);
	}

	function relayCancelFaucetPool(address account, string calldata code) external onlyPayMaster {
		require(isBeamioAccount[account], "not beamio account");
		BeamioAccount(payable(account)).cancelFaucetPool(code);
	}

	function relayFaucetRedeemPool(
		address account,
		string calldata password,
		address claimer,
		address to,
		ContainerItem[] calldata items
	) external onlyPayMaster {
		require(isBeamioAccount[account], "not beamio account");
		BeamioAccount(payable(account)).faucetRedeemPool(password, claimer, to, items);
	}

	/// @notice 通用：owner 离线签名授权对 account 的 Container module 任意调用，由 paymaster 代付 gas。支持 createRedeem、cancelRedeem、createFaucetPool、cancelFaucetPool 等。
	function executeForOwner(
		address account,
		bytes calldata data,
		uint256 deadline,
		bytes32 nonce,
		bytes calldata ownerSignature
	) external onlyPayMaster {
		require(isBeamioAccount[account], "not beamio account");
		require(account != address(0) && account.code.length > 0, "bad account");
		require(data.length > 0, "empty data");
		require(block.timestamp <= deadline, "expired");

		address accountOwner = BeamioAccount(payable(account)).owner();

		bytes32 structHash = keccak256(abi.encode(
			EXECUTE_FOR_OWNER_TYPEHASH,
			account,
			keccak256(data),
			deadline,
			nonce
		));
		bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
		address signer = ECDSA.recover(digest, ownerSignature);
		require(signer == accountOwner, "signer not owner");

		bytes32 nonceKey = keccak256(abi.encode(account, nonce));
		require(!usedOwnerExecuteNonces[nonceKey], "nonce used");
		usedOwnerExecuteNonces[nonceKey] = true;

		BeamioAccount(payable(account)).executeFromFactory(data);
	}

	/// @notice redeemer/claimer 离线签名授权执行 redeem 或 faucetRedeemPool，由 paymaster 代付 gas。发起人签名后由后端调用此入口。
	function executeForRedeemer(
		address account,
		bytes calldata data,
		uint256 deadline,
		bytes32 nonce,
		bytes calldata redeemerSignature
	) external onlyPayMaster {
		require(isBeamioAccount[account], "not beamio account");
		require(account != address(0) && account.code.length > 0, "bad account");
		require(data.length >= 4, "empty data");
		require(block.timestamp <= deadline, "expired");

		bytes4 selector;
		assembly {
			selector := calldataload(data.offset)
		}
		require(
			selector == IBeamioContainerModuleV07.redeem.selector ||
			selector == IBeamioContainerModuleV07.faucetRedeemPool.selector,
			"invalid selector"
		);

		bytes32 structHash = keccak256(abi.encode(
			EXECUTE_FOR_REDEEMER_TYPEHASH,
			account,
			keccak256(data),
			deadline,
			nonce
		));
		bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
		address signer = ECDSA.recover(digest, redeemerSignature);
		require(signer != address(0), "invalid sig");

		address expectedSigner;
		if (selector == IBeamioContainerModuleV07.redeem.selector) {
			(, address to) = abi.decode(data[4:], (string, address));
			expectedSigner = to;
		} else {
			// faucetRedeemPool(string, address claimer, address to, ContainerItem[])
			(, address claimer, address to,) = abi.decode(
				data[4:],
				(string, address, address, ContainerItem[])
			);
			expectedSigner = claimer;
			if (to != claimer) revert RedeemerToMustEqualClaimer(); // 禁止代领到第三方
		}
		if (signer != expectedSigner) revert RedeemerSignerMismatch(signer, expectedSigner);

		bytes32 nonceKey = keccak256(abi.encode(bytes32(uint256(1)), account, nonce));
		require(!usedRedeemerExecuteNonces[nonceKey], "nonce used");
		usedRedeemerExecuteNonces[nonceKey] = true;

		BeamioAccount(payable(account)).executeFromFactory(data);
	}

	receive() external payable {}
}
