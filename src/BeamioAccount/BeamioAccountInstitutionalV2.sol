// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * BeamioAccountInstitutionalV2 — institutional-grade AA (accountVersion = 2).
 *
 * - On-chain multisig tasks (no EntryPoint-nonce task identity)
 * - Native/ERC20 transfer reserved; policy-lock freezes transfer voting
 * - Fact-cancel when rejects make threshold unreachable
 * - No container / createRedeem entrypoints (institutional path)
 *
 * See: .cursor/rules/beamio-aa-account-dev.mdc
 */

import "./BeamioTypesV07.sol";
import "../contracts/utils/cryptography/ECDSA.sol";
import "../contracts/utils/cryptography/MessageHashUtils.sol";

interface IERC20Minimal {
	function balanceOf(address account) external view returns (uint256);
	function transfer(address to, uint256 amount) external returns (bool);
}

contract BeamioAccountInstitutionalV2 is IAccountV07 {
	uint256 public constant ACCOUNT_VERSION = 2;

	enum TaskKind {
		None,
		Transfer,
		SetPolicy
	}

	enum TaskStatus {
		None,
		Pending,
		Executed,
		Cancelled,
		Expired
	}

	struct Task {
		TaskKind kind;
		TaskStatus status;
		address proposer;
		address token; // address(0) = native
		address to;
		uint256 amount;
		uint256 thresholdSnap;
		uint256 approveCount;
		uint256 rejectCount;
		uint64 deadline;
		bytes32 managersHash;
		address[] managersSnap;
	}

	IEntryPointV07 public immutable entryPoint;
	address public owner;
	address public factory;
	bool private initialized;

	mapping(address => bool) public isThresholdManager;
	address[] public thresholdManagers;
	uint256 public threshold;

	uint256 public nextTaskId;
	mapping(uint256 => Task) private _tasks;
	mapping(uint256 => mapping(address => uint8)) public taskVote; // 0 none, 1 approve, 2 reject
	mapping(address => uint256) public reservedOf; // token => reserved amount
	uint256 public pendingPolicyTaskId; // 0 = unlocked

	mapping(bytes32 => bool) public usedSigNonces;

	bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
		keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
	bytes32 private constant _NAME_HASH = keccak256(bytes("BeamioAccountInstitutionalV2"));
	bytes32 private constant _VERSION_HASH = keccak256(bytes("2"));

	bytes32 public constant PROPOSE_TRANSFER_TYPEHASH =
		keccak256(
			"ProposeTransfer(address account,address token,address to,uint256 amount,uint64 deadline,bytes32 nonce)"
		);
	bytes32 public constant PROPOSE_SET_POLICY_TYPEHASH =
		keccak256(
			"ProposeSetPolicy(address account,bytes32 managersHash,uint256 newThreshold,uint64 deadline,bytes32 nonce)"
		);
	bytes32 public constant VOTE_TYPEHASH =
		keccak256("Vote(address account,uint256 taskId,bool approve,uint64 deadline,bytes32 nonce)");

	error NotAuthorized();
	error NotFactory();
	error NotEntryPoint();
	error AlreadyInitialized();
	error ZeroAddress();
	error BadTask();
	error PolicyLocked();
	error InsufficientSpendable();
	error DeadlineExpired();
	error NonceUsed();
	error BadSignature();
	error AlreadyVoted();
	error TransferVotingFrozen();

	event Initialized(address indexed owner, address indexed factory);
	event ThresholdPolicyUpdated(bytes32 indexed managersHash, uint256 threshold);
	event TaskProposed(uint256 indexed taskId, TaskKind kind, address indexed proposer);
	event TaskVoted(uint256 indexed taskId, address indexed voter, bool approve);
	event TaskCancelled(uint256 indexed taskId, string reason);
	event TaskExecuted(uint256 indexed taskId);
	event ReservedChanged(address indexed token, uint256 reserved);

	modifier onlyFactory() {
		if (msg.sender != factory) revert NotFactory();
		_;
	}

	modifier onlyEntryPoint() {
		if (msg.sender != address(entryPoint)) revert NotEntryPoint();
		_;
	}

	constructor(IEntryPointV07 ep) {
		entryPoint = ep;
	}

	receive() external payable {}

	function accountVersion() external pure returns (uint256) {
		return ACCOUNT_VERSION;
	}

	function isSoleSelfSigner() public view returns (bool) {
		return threshold == 1 && thresholdManagers.length == 1;
	}

	function policyLockActive() public view returns (bool) {
		uint256 id = pendingPolicyTaskId;
		if (id == 0) return false;
		Task storage t = _tasks[id];
		return t.status == TaskStatus.Pending && t.kind == TaskKind.SetPolicy;
	}

	function getTask(uint256 taskId)
		external
		view
		returns (
			TaskKind kind,
			TaskStatus status,
			address proposer,
			address token,
			address to,
			uint256 amount,
			uint256 thresholdSnap,
			uint256 approveCount,
			uint256 rejectCount,
			uint64 deadline,
			bytes32 managersHash,
			address[] memory managersSnap
		)
	{
		Task storage t = _tasks[taskId];
		return (
			t.kind,
			t.status,
			t.proposer,
			t.token,
			t.to,
			t.amount,
			t.thresholdSnap,
			t.approveCount,
			t.rejectCount,
			t.deadline,
			t.managersHash,
			t.managersSnap
		);
	}

	function spendable(address token) public view returns (uint256) {
		uint256 bal = token == address(0) ? address(this).balance : IERC20Minimal(token).balanceOf(address(this));
		uint256 r = reservedOf[token];
		return bal > r ? bal - r : 0;
	}

	function initialize(
		address _owner,
		address[] calldata managersSorted,
		uint256 _threshold,
		address _factory
	) external {
		if (initialized) revert AlreadyInitialized();
		if (_owner == address(0) || _factory == address(0)) revert ZeroAddress();
		if (managersSorted.length == 0 || managersSorted[0] != _owner) revert NotAuthorized();
		if (_threshold == 0 || _threshold > managersSorted.length) revert NotAuthorized();

		initialized = true;
		owner = _owner;
		factory = _factory;
		_setManagers(managersSorted, _threshold);
		emit Initialized(_owner, _factory);
	}

	function domainSeparator() public view returns (bytes32) {
		return
			keccak256(
				abi.encode(_EIP712_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this))
			);
	}

	function _hashTyped(bytes32 structHash) internal view returns (bytes32) {
		return MessageHashUtils.toTypedDataHash(domainSeparator(), structHash);
	}

	function _useNonce(bytes32 nonce) internal {
		if (usedSigNonces[nonce]) revert NonceUsed();
		usedSigNonces[nonce] = true;
	}

	function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
		return ECDSA.recover(digest, sig);
	}

	function _setManagers(address[] memory managersSorted, uint256 newThreshold) internal {
		if (managersSorted.length == 0 || managersSorted[0] != owner) revert NotAuthorized();
		for (uint256 i = 0; i < thresholdManagers.length; i++) {
			isThresholdManager[thresholdManagers[i]] = false;
		}
		delete thresholdManagers;
		// managers[0] == owner (any address). Co-signers at [1..] are unique, != owner,
		// and strictly ascending among themselves — owner need NOT be the lowest address.
		for (uint256 i = 0; i < managersSorted.length; i++) {
			address m = managersSorted[i];
			if (m == address(0)) revert NotAuthorized();
			if (i == 0) {
				// owner slot already checked against `owner`
			} else {
				if (m == owner) revert NotAuthorized();
				if (i >= 2 && m <= managersSorted[i - 1]) revert NotAuthorized();
			}
			isThresholdManager[m] = true;
			thresholdManagers.push(m);
		}
		if (newThreshold == 0 || newThreshold > thresholdManagers.length) revert NotAuthorized();
		threshold = newThreshold;
		emit ThresholdPolicyUpdated(keccak256(abi.encode(thresholdManagers)), threshold);
	}

	function _snapshotManagers() internal view returns (address[] memory snap, bytes32 hash) {
		uint256 n = thresholdManagers.length;
		snap = new address[](n);
		for (uint256 i = 0; i < n; i++) snap[i] = thresholdManagers[i];
		hash = keccak256(abi.encode(snap));
	}

	function _requireManager(address a) internal view {
		if (!isThresholdManager[a]) revert NotAuthorized();
	}

	/// @dev Fact-cancel: R > N - T
	function _impossible(uint256 n, uint256 t, uint256 rejects) internal pure returns (bool) {
		return rejects > n - t;
	}

	function _releaseReserve(address token, uint256 amount) internal {
		uint256 r = reservedOf[token];
		reservedOf[token] = r >= amount ? r - amount : 0;
		emit ReservedChanged(token, reservedOf[token]);
	}

	function proposeTransferWithSig(
		address token,
		address to,
		uint256 amount,
		uint64 deadline,
		bytes32 nonce,
		bytes calldata signature
	) external onlyFactory returns (uint256 taskId) {
		if (to == address(0) || amount == 0) revert BadTask();
		if (block.timestamp > deadline) revert DeadlineExpired();
		if (policyLockActive()) revert PolicyLocked();
		if (amount > spendable(token)) revert InsufficientSpendable();

		bytes32 digest = _hashTyped(
			keccak256(abi.encode(PROPOSE_TRANSFER_TYPEHASH, address(this), token, to, amount, deadline, nonce))
		);
		_useNonce(nonce);
		address proposer = _recover(digest, signature);
		_requireManager(proposer);

		(address[] memory snap, bytes32 mHash) = _snapshotManagers();
		taskId = ++nextTaskId;
		Task storage t = _tasks[taskId];
		t.kind = TaskKind.Transfer;
		t.status = TaskStatus.Pending;
		t.proposer = proposer;
		t.token = token;
		t.to = to;
		t.amount = amount;
		t.thresholdSnap = threshold;
		t.deadline = deadline;
		t.managersHash = mHash;
		t.managersSnap = snap;

		reservedOf[token] += amount;
		emit ReservedChanged(token, reservedOf[token]);
		emit TaskProposed(taskId, TaskKind.Transfer, proposer);
	}

	function proposeSetPolicyWithSig(
		address[] calldata managersSorted,
		uint256 newThreshold,
		uint64 deadline,
		bytes32 nonce,
		bytes calldata signature
	) external onlyFactory returns (uint256 taskId) {
		if (block.timestamp > deadline) revert DeadlineExpired();
		if (policyLockActive()) revert PolicyLocked();
		if (managersSorted.length == 0 || managersSorted[0] != owner) revert NotAuthorized();
		if (newThreshold == 0 || newThreshold > managersSorted.length) revert NotAuthorized();

		bytes32 proposedManagersHash = keccak256(abi.encode(managersSorted));
		bytes32 digest = _hashTyped(
			keccak256(
				abi.encode(
					PROPOSE_SET_POLICY_TYPEHASH,
					address(this),
					proposedManagersHash,
					newThreshold,
					deadline,
					nonce
				)
			)
		);
		_useNonce(nonce);
		address proposer = _recover(digest, signature);
		_requireManager(proposer);

		(address[] memory snap, bytes32 votersHash) = _snapshotManagers();
		taskId = ++nextTaskId;
		Task storage t = _tasks[taskId];
		t.kind = TaskKind.SetPolicy;
		t.status = TaskStatus.Pending;
		t.proposer = proposer;
		t.amount = newThreshold;
		t.thresholdSnap = threshold;
		t.deadline = deadline;
		t.managersHash = votersHash;
		t.managersSnap = snap;
		_proposedManagers[taskId] = managersSorted;

		pendingPolicyTaskId = taskId;
		emit TaskProposed(taskId, TaskKind.SetPolicy, proposer);
	}

	mapping(uint256 => address[]) private _proposedManagers;

	function proposedManagers(uint256 taskId) external view returns (address[] memory) {
		return _proposedManagers[taskId];
	}

	function voteWithSig(
		uint256 taskId,
		bool approve,
		uint64 deadline,
		bytes32 nonce,
		bytes calldata signature
	) external onlyFactory {
		if (block.timestamp > deadline) revert DeadlineExpired();
		Task storage t = _tasks[taskId];
		if (t.status != TaskStatus.Pending) revert BadTask();
		if (block.timestamp > t.deadline) {
			_cancelTask(taskId, "Expired");
			return;
		}

		bytes32 digest = _hashTyped(
			keccak256(abi.encode(VOTE_TYPEHASH, address(this), taskId, approve, deadline, nonce))
		);
		_useNonce(nonce);
		address voter = _recover(digest, signature);

		bool isVoter;
		for (uint256 i = 0; i < t.managersSnap.length; i++) {
			if (t.managersSnap[i] == voter) {
				isVoter = true;
				break;
			}
		}
		if (!isVoter) revert NotAuthorized();
		if (taskVote[taskId][voter] != 0) revert AlreadyVoted();

		if (t.kind == TaskKind.Transfer && policyLockActive() && pendingPolicyTaskId != taskId) {
			revert TransferVotingFrozen();
		}

		taskVote[taskId][voter] = approve ? 1 : 2;
		if (approve) t.approveCount += 1;
		else t.rejectCount += 1;
		emit TaskVoted(taskId, voter, approve);

		uint256 n = t.managersSnap.length;
		if (_impossible(n, t.thresholdSnap, t.rejectCount)) {
			_cancelTask(taskId, "ImpossibleThreshold");
			return;
		}
		if (t.approveCount >= t.thresholdSnap) {
			_executeTask(taskId);
		}
	}

	function _cancelTask(uint256 taskId, string memory reason) internal {
		Task storage t = _tasks[taskId];
		if (t.status != TaskStatus.Pending) return;
		t.status = keccak256(bytes(reason)) == keccak256(bytes("Expired"))
			? TaskStatus.Expired
			: TaskStatus.Cancelled;
		if (t.kind == TaskKind.Transfer) {
			_releaseReserve(t.token, t.amount);
		}
		if (pendingPolicyTaskId == taskId) pendingPolicyTaskId = 0;
		emit TaskCancelled(taskId, reason);
	}

	function _executeTask(uint256 taskId) internal {
		Task storage t = _tasks[taskId];
		if (t.status != TaskStatus.Pending) revert BadTask();
		t.status = TaskStatus.Executed;

		if (t.kind == TaskKind.Transfer) {
			_releaseReserve(t.token, t.amount);
			if (t.token == address(0)) {
				(bool ok, ) = t.to.call{value: t.amount}("");
				if (!ok) revert NotAuthorized();
			} else {
				if (!IERC20Minimal(t.token).transfer(t.to, t.amount)) revert NotAuthorized();
			}
		} else if (t.kind == TaskKind.SetPolicy) {
			address[] memory proposed = _proposedManagers[taskId];
			_setManagers(proposed, t.amount);
			if (pendingPolicyTaskId == taskId) pendingPolicyTaskId = 0;
		}

		emit TaskExecuted(taskId);
	}

	/// @notice Sole 1-of-1 path: EntryPoint execute (Express-like institutional before cosigners).
	function execute(address dest, uint256 value, bytes calldata func) external onlyEntryPoint {
		if (!isSoleSelfSigner()) revert NotAuthorized();
		(bool ok, bytes memory ret) = dest.call{value: value}(func);
		if (!ok) {
			assembly {
				revert(add(ret, 32), mload(ret))
			}
		}
	}

	function validateUserOp(
		PackedUserOperation calldata userOp,
		bytes32 userOpHash,
		uint256 missingAccountFunds
	) external override onlyEntryPoint returns (uint256 validationData) {
		if (!isSoleSelfSigner()) return 1;
		bytes32 hash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
		address signer = ECDSA.recover(hash, userOp.signature);
		if (signer != owner) return 1;
		if (missingAccountFunds > 0) {
			(bool ok, ) = payable(msg.sender).call{value: missingAccountFunds}("");
			ok;
		}
		return 0;
	}
}
