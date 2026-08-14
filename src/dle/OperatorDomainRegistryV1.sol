// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {DLEUpgradeableBase} from "./DLEUpgradeableBase.sol";

/// @notice L1 operator identity, infrastructure and role-domain registry.
/// @dev The deterministic evaluator fails closed: incomplete/stale evidence is
/// UNKNOWN; conflicts, disputes and policy breaches are INELIGIBLE.
contract OperatorDomainRegistryV1 is DLEUpgradeableBase {
    enum Decision {
        UNKNOWN,
        ELIGIBLE,
        INELIGIBLE
    }

    enum RecordStatus {
        NONE,
        PENDING,
        ACTIVE,
        DISPUTED,
        SUSPENDED,
        MERGED,
        COOLDOWN,
        RETIRED
    }

    struct OperatorRecordV1 {
        bytes32 controlCommitment;
        bytes32 organizationCommitment;
        bytes32 beneficiaryCommitment;
        uint64 validFrom;
        uint64 validUntil;
        uint64 evidenceEpoch;
        RecordStatus status;
        bytes32 mergedInto;
    }

    struct InfrastructureClaimV1 {
        bytes32 exactTenantId;
        bytes32 providerId;
        bytes32 regionId;
        bytes32 facilityId;
        bytes32 networkPrefixId;
        bytes32 billingEntityId;
        uint64 validUntil;
        bool disputed;
    }

    struct DomainChallengeV1 {
        bytes32 canonicalOperatorId;
        address challenger;
        uint256 bond;
        uint64 openedAt;
        uint64 resolveAfter;
        bytes32 evidenceHash;
        bool resolved;
        bool upheld;
    }

    error EmptyId();
    error UnknownOperator();
    error InvalidValidity();
    error AliasAlreadyBound();
    error MergeCycle();
    error InvalidChallenge();
    error DuplicateChallengeEvidence();
    error ChallengeAlreadyResolved();
    error ChallengeResolveTooEarly();
    error RefundTransferFailed();

    uint8 public maxSameProvider;
    uint8 public maxSameRegion;
    uint8 public maxSameFacility;
    uint64 public minimumEvidenceLifetime;
    uint64 public policyEpoch;
    uint64 public challengePeriod;
    uint256 public minimumChallengeBond;
    uint64 public nextChallengeId;

    mapping(bytes32 => OperatorRecordV1) public operatorRecords;
    mapping(bytes32 => InfrastructureClaimV1) public infrastructureClaims;
    mapping(bytes32 => bytes32) public canonicalOperatorOfAlias;
    mapping(bytes32 => bool) public archiveRoleActive;
    mapping(bytes32 => bool) public validatorRoleActive;
    mapping(uint64 => DomainChallengeV1) public domainChallenges;
    mapping(bytes32 => bool) public challengeEvidenceUsed;
    mapping(bytes32 => uint64) public cooldownUntil;
    mapping(address => uint256) public challengeRefunds;

    event OperatorRecordSet(bytes32 indexed canonicalOperatorId, RecordStatus status, uint64 evidenceEpoch);
    event InfrastructureClaimSet(bytes32 indexed canonicalOperatorId, bytes32 exactTenantId, uint64 validUntil);
    event IdentityAliasBound(bytes32 indexed aliasId, bytes32 indexed canonicalOperatorId);
    event OperatorMerged(bytes32 indexed sourceId, bytes32 indexed targetId);
    event RoleUsageSet(bytes32 indexed canonicalOperatorId, bool archiveActive, bool validatorActive);
    event PolicySet(uint64 indexed policyEpoch, uint8 maxProvider, uint8 maxRegion, uint8 maxFacility);
    event DomainChallengeOpened(
        uint64 indexed challengeId,
        bytes32 indexed canonicalOperatorId,
        address indexed challenger,
        bytes32 evidenceHash
    );
    event DomainChallengeResolved(uint64 indexed challengeId, bool upheld, RecordStatus status);
    event CooldownSet(bytes32 indexed canonicalOperatorId, uint64 until);
    event ChallengeRefundWithdrawn(address indexed challenger, uint256 amount);

    function initialize(address initialOwner) external initializer {
        __DLEUpgradeableBase_init(initialOwner);
        maxSameProvider = 2;
        maxSameRegion = 2;
        maxSameFacility = 2;
        minimumEvidenceLifetime = 1 days;
        policyEpoch = 1;
        challengePeriod = 1 days;
        minimumChallengeBond = 0.01 ether;
        nextChallengeId = 1;
    }

    function setPolicy(
        uint8 providerLimit,
        uint8 regionLimit,
        uint8 facilityLimit,
        uint64 evidenceLifetime
    ) external onlyOwner {
        if (providerLimit == 0 || regionLimit == 0 || facilityLimit == 0) revert InvalidValidity();
        maxSameProvider = providerLimit;
        maxSameRegion = regionLimit;
        maxSameFacility = facilityLimit;
        minimumEvidenceLifetime = evidenceLifetime;
        emit PolicySet(++policyEpoch, providerLimit, regionLimit, facilityLimit);
    }

    function setChallengePolicy(uint64 challengePeriod_, uint256 minimumChallengeBond_) external onlyOwner {
        if (challengePeriod_ == 0) revert InvalidValidity();
        challengePeriod = challengePeriod_;
        minimumChallengeBond = minimumChallengeBond_;
    }

    function setOperatorRecord(bytes32 canonicalOperatorId, OperatorRecordV1 calldata record) external onlyOwner {
        if (canonicalOperatorId == bytes32(0)) revert EmptyId();
        if (record.validUntil <= record.validFrom) revert InvalidValidity();
        operatorRecords[canonicalOperatorId] = record;
        if (canonicalOperatorOfAlias[canonicalOperatorId] == bytes32(0)) {
            canonicalOperatorOfAlias[canonicalOperatorId] = canonicalOperatorId;
        }
        emit OperatorRecordSet(canonicalOperatorId, record.status, record.evidenceEpoch);
    }

    function setInfrastructureClaim(
        bytes32 canonicalOperatorId,
        InfrastructureClaimV1 calldata claim
    ) external onlyOwner {
        if (resolveCanonical(canonicalOperatorId) == bytes32(0)) revert UnknownOperator();
        infrastructureClaims[canonicalOperatorId] = claim;
        emit InfrastructureClaimSet(canonicalOperatorId, claim.exactTenantId, claim.validUntil);
    }

    function bindIdentityAlias(bytes32 aliasId, bytes32 canonicalOperatorId) external onlyOwner {
        if (aliasId == bytes32(0) || canonicalOperatorId == bytes32(0)) revert EmptyId();
        if (canonicalOperatorOfAlias[aliasId] != bytes32(0)) revert AliasAlreadyBound();
        if (operatorRecords[canonicalOperatorId].status == RecordStatus.NONE) revert UnknownOperator();
        canonicalOperatorOfAlias[aliasId] = canonicalOperatorId;
        emit IdentityAliasBound(aliasId, canonicalOperatorId);
    }

    function mergeOperator(bytes32 sourceId, bytes32 targetId) external onlyOwner {
        bytes32 source = resolveCanonical(sourceId);
        bytes32 target = resolveCanonical(targetId);
        if (source == bytes32(0) || target == bytes32(0)) revert UnknownOperator();
        if (source == target) revert MergeCycle();
        operatorRecords[source].status = RecordStatus.MERGED;
        operatorRecords[source].mergedInto = target;
        canonicalOperatorOfAlias[source] = target;
        emit OperatorMerged(source, target);
    }

    function setRoleUsage(bytes32 canonicalOperatorId, bool archiveActive, bool validatorActive) external onlyOwner {
        bytes32 canonical = resolveCanonical(canonicalOperatorId);
        if (canonical == bytes32(0)) revert UnknownOperator();
        archiveRoleActive[canonical] = archiveActive;
        validatorRoleActive[canonical] = validatorActive;
        emit RoleUsageSet(canonical, archiveActive, validatorActive);
    }

    /// @notice Opens a bonded, evidence-nullified domain challenge. A challenged
    /// operator is immediately ineligible for new group placement; historical
    /// group roots remain unchanged.
    function openDomainChallenge(bytes32 identityId, bytes32 evidenceHash) external payable returns (uint64 challengeId) {
        bytes32 canonical = resolveCanonical(identityId);
        if (
            canonical == bytes32(0) ||
            evidenceHash == bytes32(0) ||
            msg.value < minimumChallengeBond
        ) revert InvalidChallenge();
        if (challengeEvidenceUsed[evidenceHash]) revert DuplicateChallengeEvidence();

        OperatorRecordV1 storage record = operatorRecords[canonical];
        if (record.status != RecordStatus.ACTIVE) revert InvalidChallenge();
        record.status = RecordStatus.DISPUTED;
        challengeEvidenceUsed[evidenceHash] = true;
        challengeId = nextChallengeId++;
        domainChallenges[challengeId] = DomainChallengeV1({
            canonicalOperatorId: canonical,
            challenger: msg.sender,
            bond: msg.value,
            openedAt: uint64(block.timestamp),
            resolveAfter: uint64(block.timestamp) + challengePeriod,
            evidenceHash: evidenceHash,
            resolved: false,
            upheld: false
        });
        emit DomainChallengeOpened(challengeId, canonical, msg.sender, evidenceHash);
    }

    /// @notice Resolves a frozen evidence record. It intentionally does not
    /// mutate historical archive membership roots; replacement/re-home is a
    /// separate certificate-controlled action.
    function resolveDomainChallenge(uint64 challengeId, bool upheld) external onlyOwner {
        DomainChallengeV1 storage challenge = domainChallenges[challengeId];
        if (challenge.canonicalOperatorId == bytes32(0)) revert InvalidChallenge();
        if (challenge.resolved) revert ChallengeAlreadyResolved();
        if (block.timestamp < challenge.resolveAfter) revert ChallengeResolveTooEarly();

        challenge.resolved = true;
        challenge.upheld = upheld;
        OperatorRecordV1 storage record = operatorRecords[challenge.canonicalOperatorId];
        record.status = upheld ? RecordStatus.SUSPENDED : RecordStatus.ACTIVE;
        challengeRefunds[challenge.challenger] += challenge.bond;
        emit DomainChallengeResolved(challengeId, upheld, record.status);
    }

    function setCooldown(bytes32 identityId, uint64 until) external onlyOwner {
        bytes32 canonical = resolveCanonical(identityId);
        if (canonical == bytes32(0) || until <= block.timestamp) revert InvalidValidity();
        cooldownUntil[canonical] = until;
        operatorRecords[canonical].status = RecordStatus.COOLDOWN;
        emit CooldownSet(canonical, until);
    }

    function clearExpiredCooldown(bytes32 identityId) external {
        bytes32 canonical = resolveCanonical(identityId);
        if (
            canonical == bytes32(0) ||
            operatorRecords[canonical].status != RecordStatus.COOLDOWN ||
            cooldownUntil[canonical] > block.timestamp
        ) revert InvalidValidity();
        operatorRecords[canonical].status = RecordStatus.ACTIVE;
    }

    function withdrawChallengeRefund() external {
        uint256 amount = challengeRefunds[msg.sender];
        if (amount == 0) revert InvalidChallenge();
        challengeRefunds[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert RefundTransferFailed();
        emit ChallengeRefundWithdrawn(msg.sender, amount);
    }

    function resolveCanonical(bytes32 identityId) public view returns (bytes32 canonical) {
        canonical = canonicalOperatorOfAlias[identityId];
        if (canonical == bytes32(0) && operatorRecords[identityId].status != RecordStatus.NONE) {
            canonical = identityId;
        }
        for (uint8 i; i < 8 && canonical != bytes32(0); ++i) {
            bytes32 mergedInto = operatorRecords[canonical].mergedInto;
            if (mergedInto == bytes32(0)) return canonical;
            canonical = mergedInto;
        }
        return bytes32(0);
    }

    function evaluateCandidateSet(
        bytes32[] calldata identityIds,
        bool rejectArchiveValidatorOverlap
    ) external view returns (Decision decision, bytes32 reasonCode) {
        uint256 length = identityIds.length;
        if (length != 7) return (Decision.INELIGIBLE, keccak256("DLE_BAD_GROUP_WIDTH"));

        bytes32[] memory canonical = new bytes32[](length);
        for (uint256 i; i < length; ++i) {
            canonical[i] = resolveCanonical(identityIds[i]);
            if (canonical[i] == bytes32(0)) return (Decision.UNKNOWN, keccak256("DLE_IDENTITY_UNKNOWN"));

            OperatorRecordV1 storage record = operatorRecords[canonical[i]];
            if (record.status == RecordStatus.PENDING || record.status == RecordStatus.NONE) {
                return (Decision.UNKNOWN, keccak256("DLE_EVIDENCE_INCOMPLETE"));
            }
            if (record.status != RecordStatus.ACTIVE) {
                return (Decision.INELIGIBLE, keccak256("DLE_OPERATOR_NOT_ACTIVE"));
            }
            if (cooldownUntil[canonical[i]] > block.timestamp) {
                return (Decision.INELIGIBLE, keccak256("DLE_OPERATOR_COOLDOWN"));
            }
            if (
                record.validFrom > block.timestamp ||
                record.validUntil < block.timestamp + minimumEvidenceLifetime
            ) {
                return (Decision.UNKNOWN, keccak256("DLE_EVIDENCE_STALE"));
            }

            InfrastructureClaimV1 storage claim = infrastructureClaims[canonical[i]];
            if (claim.exactTenantId == bytes32(0) || claim.providerId == bytes32(0)) {
                return (Decision.UNKNOWN, keccak256("DLE_INFRA_UNKNOWN"));
            }
            if (claim.validUntil < block.timestamp + minimumEvidenceLifetime) {
                return (Decision.UNKNOWN, keccak256("DLE_INFRA_STALE"));
            }
            if (claim.disputed) return (Decision.INELIGIBLE, keccak256("DLE_INFRA_DISPUTED"));
            if (
                rejectArchiveValidatorOverlap &&
                archiveRoleActive[canonical[i]] &&
                validatorRoleActive[canonical[i]]
            ) {
                return (Decision.INELIGIBLE, keccak256("DLE_ROLE_OVERLAP"));
            }

            uint8 providerCount = 1;
            uint8 regionCount = 1;
            uint8 facilityCount = 1;
            for (uint256 j; j < i; ++j) {
                if (canonical[j] == canonical[i]) {
                    return (Decision.INELIGIBLE, keccak256("DLE_OPERATOR_DUPLICATE"));
                }
                InfrastructureClaimV1 storage previous = infrastructureClaims[canonical[j]];
                if (previous.exactTenantId == claim.exactTenantId) {
                    return (Decision.INELIGIBLE, keccak256("DLE_EXACT_TENANT_DUPLICATE"));
                }
                if (previous.providerId == claim.providerId) ++providerCount;
                if (previous.regionId == claim.regionId) ++regionCount;
                if (previous.facilityId == claim.facilityId) ++facilityCount;
            }
            if (providerCount > maxSameProvider) {
                return (Decision.INELIGIBLE, keccak256("DLE_PROVIDER_CONCENTRATION"));
            }
            if (regionCount > maxSameRegion) {
                return (Decision.INELIGIBLE, keccak256("DLE_REGION_CONCENTRATION"));
            }
            if (facilityCount > maxSameFacility) {
                return (Decision.INELIGIBLE, keccak256("DLE_FACILITY_CONCENTRATION"));
            }
        }
        return (Decision.ELIGIBLE, bytes32(0));
    }

    uint256[32] private __gap;
}
