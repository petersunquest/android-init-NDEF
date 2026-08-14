/**
 * Canonical, address-free manifest for the CoNET-DLE MVP deployment.
 *
 * This module intentionally contains no signer, RPC, or transaction code.  The
 * addresses and initializer values belong to a generated deployment record only
 * after an operator has completed a real deployment.
 */

export const DLE_RECORD_SCHEMA = "conet-dle-deployment-v1";
export const DLE_CHAIN_ID = 224422;
export const DLE_SOLC_VERSION = "0.8.35";
export const DLE_PROXY_SOURCE_KEY = "project/src/dle/DLEERC1967Proxy.sol";
export const DLE_PROXY_CONTRACT_NAME = "DLEERC1967Proxy";

function implementation(key, sourceFile, contractName) {
  return {
    key,
    kind: "implementation",
    sourceKey: `project/src/dle/${sourceFile}`,
    contractName,
  };
}

function proxy(key, implementationKey, initializerSignature) {
  return {
    key,
    kind: "proxy",
    sourceKey: DLE_PROXY_SOURCE_KEY,
    contractName: DLE_PROXY_CONTRACT_NAME,
    implementationKey,
    initializerSignature,
  };
}

export const DLE_COMPONENTS = Object.freeze([
  implementation(
    "OperatorDomainRegistryV1Implementation",
    "OperatorDomainRegistryV1.sol",
    "OperatorDomainRegistryV1",
  ),
  proxy(
    "OperatorDomainRegistryV1Proxy",
    "OperatorDomainRegistryV1Implementation",
    "initialize(address)",
  ),
  implementation(
    "ArchiveGroupRegistryV1Implementation",
    "ArchiveGroupRegistryV1.sol",
    "ArchiveGroupRegistryV1",
  ),
  proxy(
    "ArchiveGroupRegistryV1Proxy",
    "ArchiveGroupRegistryV1Implementation",
    "initialize(address,address)",
  ),
  implementation(
    "ArchiveCertificateVerifierV1Implementation",
    "ArchiveCertificateVerifierV1.sol",
    "ArchiveCertificateVerifierV1",
  ),
  proxy(
    "ArchiveCertificateVerifierV1Proxy",
    "ArchiveCertificateVerifierV1Implementation",
    "initialize(address,address)",
  ),
  implementation(
    "DLEChainRegistry1155V1Implementation",
    "DLEChainRegistry1155V1.sol",
    "DLEChainRegistry1155V1",
  ),
  proxy(
    "DLEChainRegistry1155V1Proxy",
    "DLEChainRegistry1155V1Implementation",
    "initialize(address,string,address,address,address)",
  ),
  implementation(
    "AssetAdmissionRegistryV1Implementation",
    "AssetAdmissionRegistryV1.sol",
    "AssetAdmissionRegistryV1",
  ),
  proxy(
    "AssetAdmissionRegistryV1Proxy",
    "AssetAdmissionRegistryV1Implementation",
    "initialize(address)",
  ),
  implementation(
    "DLEArchiveDisputeManagerV1Implementation",
    "DLEArchiveDisputeManagerV1.sol",
    "DLEArchiveDisputeManagerV1",
  ),
  proxy(
    "DLEArchiveDisputeManagerV1Proxy",
    "DLEArchiveDisputeManagerV1Implementation",
    "initialize(address,uint64,uint256)",
  ),
  implementation(
    "AssetBurnMintGatewayImplementation",
    "AssetBurnMintGateway.sol",
    "AssetBurnMintGateway",
  ),
  proxy(
    "AssetBurnMintGatewayProxy",
    "AssetBurnMintGatewayImplementation",
    "initialize(address,address,address,address,address,uint64,uint64)",
  ),
  implementation(
    "L1QueueAccumulatorV1Implementation",
    "L1QueueAccumulatorV1.sol",
    "L1QueueAccumulatorV1",
  ),
  proxy(
    "L1QueueAccumulatorV1Proxy",
    "L1QueueAccumulatorV1Implementation",
    "initialize(address)",
  ),
]);

export const DLE_IMPLEMENTATION_ORDER = Object.freeze(
  DLE_COMPONENTS.filter((component) => component.kind === "implementation").map(
    (component) => component.key,
  ),
);

export const DLE_PROXY_ORDER = Object.freeze(
  DLE_COMPONENTS.filter((component) => component.kind === "proxy").map(
    (component) => component.key,
  ),
);

export const DLE_COMPONENT_BY_KEY = Object.freeze(
  Object.fromEntries(DLE_COMPONENTS.map((component) => [component.key, component])),
);
