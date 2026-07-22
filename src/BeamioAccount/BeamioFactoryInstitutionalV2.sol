// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * BeamioFactoryInstitutionalV2 — V2 institutional AA factory (CREATE2 salt v2).
 * Creates BeamioAccountInstitutionalV2; relays propose/vote with paymaster gas.
 * Does not replace V1 BeamioFactoryPaymasterV07.
 *
 * See: .cursor/rules/beamio-aa-account-dev.mdc
 */

import "./BeamioTypesV07.sol";
import "./BeamioAccountCreate2Lib.sol";
import "./BeamioAccountInstitutionalV2.sol";

contract BeamioFactoryInstitutionalV2 is IPaymasterV07 {
	uint256 public constant FACTORY_VERSION = 2;

	IEntryPointV07 public constant ENTRY_POINT =
		IEntryPointV07(0x0000000071727De22E5E9d8BAf0edAc6f37da032);

	mapping(address => bool) public isBeamioAccount;
	address public admin;
	mapping(address => uint256) public nextIndexOfCreator;
	mapping(address => address[]) internal accountsByCreator;
	address[] public payMasters;
	mapping(address => bool) public isPayMaster;
	uint256 public accountLimit;

	event AccountCreated(address indexed creator, address indexed account, uint256 index, bytes32 salt);
	event AdminUpdated(address indexed admin);
	event PayMasterUpdated(address indexed payMaster, bool enabled);

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

	constructor(uint256 initialAccountLimit, address admin_) {
		require(initialAccountLimit > 0, "limit=0");
		require(admin_ != address(0), "zero admin");
		admin = admin_;
		accountLimit = initialAccountLimit;
		isPayMaster[admin_] = true;
		payMasters.push(admin_);
	}

	function factoryVersion() external pure returns (uint256) {
		return FACTORY_VERSION;
	}

	function transferAdmin(address newAdmin) external onlyAdmin {
		require(newAdmin != address(0), "zero admin");
		admin = newAdmin;
		emit AdminUpdated(newAdmin);
	}

	function setAccountLimit(uint256 newLimit) external onlyAdmin {
		require(newLimit > 0, "limit=0");
		accountLimit = newLimit;
	}

	function setPayMaster(address pm, bool enabled) external onlyAdmin {
		require(pm != address(0), "zero");
		if (enabled && !isPayMaster[pm]) {
			isPayMaster[pm] = true;
			payMasters.push(pm);
		} else if (!enabled) {
			isPayMaster[pm] = false;
		}
		emit PayMasterUpdated(pm, enabled);
	}

	function computeSalt(address creator, uint256 index) public pure returns (bytes32) {
		return keccak256(abi.encode(keccak256("beamio.aa.v2"), creator, index));
	}

	function _initCode() internal pure returns (bytes memory) {
		return abi.encodePacked(type(BeamioAccountInstitutionalV2).creationCode, abi.encode(ENTRY_POINT));
	}

	function getAddress(address creator, uint256 index) public pure returns (address) {
		bytes32 salt = computeSalt(creator, index);
		bytes32 initCodeHash = keccak256(_initCode());
		return BeamioAccountCreate2Lib.predict(salt, initCodeHash);
	}

	function myAccounts(address creator) external view returns (address[] memory) {
		return accountsByCreator[creator];
	}

	function createAccountFor(address creator) external onlyPayMaster returns (address account) {
		require(creator != address(0), "zero creator");
		return _createAccountAtNextIndex(creator);
	}

	function createAccount() external returns (address account) {
		return _createAccountAtNextIndex(msg.sender);
	}

	function _createAccountAtNextIndex(address creator) internal returns (address account) {
		uint256 index = nextIndexOfCreator[creator];
		require(index < accountLimit, "limit");

		account = getAddress(creator, index);
		nextIndexOfCreator[creator] = index + 1;

		if (account.code.length > 0) {
			if (!isBeamioAccount[account]) {
				isBeamioAccount[account] = true;
				accountsByCreator[creator].push(account);
			}
			return account;
		}

		bytes32 salt = computeSalt(creator, index);
		account = BeamioAccountCreate2Lib.nickDeploy(salt, _initCode());

		address[] memory managers = new address[](1);
		managers[0] = creator;
		BeamioAccountInstitutionalV2(payable(account)).initialize(creator, managers, 1, address(this));

		isBeamioAccount[account] = true;
		accountsByCreator[creator].push(account);
		emit AccountCreated(creator, account, index, salt);
		return account;
	}

	function validatePaymasterUserOp(
		PackedUserOperation calldata userOp,
		bytes32,
		uint256
	) external view override onlyEntryPoint returns (bytes memory context, uint256 validationData) {
		if (!isBeamioAccount[userOp.sender]) return ("", 1);
		return ("", 0);
	}

	function postOp(PostOpMode, bytes calldata, uint256, uint256) external override onlyEntryPoint {}

	function depositToEntryPoint() external payable onlyAdmin {
		ENTRY_POINT.depositTo{value: msg.value}(address(this));
	}

	function proposeTransfer(
		address account,
		address token,
		address to,
		uint256 amount,
		uint64 deadline,
		bytes32 nonce,
		bytes calldata signature
	) external onlyPayMaster returns (uint256 taskId) {
		require(isBeamioAccount[account], "not aa");
		return
			BeamioAccountInstitutionalV2(payable(account)).proposeTransferWithSig(
				token,
				to,
				amount,
				deadline,
				nonce,
				signature
			);
	}

	function proposeSetPolicy(
		address account,
		address[] calldata managersSorted,
		uint256 newThreshold,
		uint64 deadline,
		bytes32 nonce,
		bytes calldata signature
	) external onlyPayMaster returns (uint256 taskId) {
		require(isBeamioAccount[account], "not aa");
		return
			BeamioAccountInstitutionalV2(payable(account)).proposeSetPolicyWithSig(
				managersSorted,
				newThreshold,
				deadline,
				nonce,
				signature
			);
	}

	function vote(
		address account,
		uint256 taskId,
		bool approve,
		uint64 deadline,
		bytes32 nonce,
		bytes calldata signature
	) external onlyPayMaster {
		require(isBeamioAccount[account], "not aa");
		BeamioAccountInstitutionalV2(payable(account)).voteWithSig(
			taskId,
			approve,
			deadline,
			nonce,
			signature
		);
	}
}
