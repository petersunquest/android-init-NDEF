#!/usr/bin/env node
/**
 * 部署新工厂 (含 executeForAdmin) + 新 CCSA 卡，并更新引用
 * 用法: node scripts/deployNewFactoryAndCCSA.js
 */
const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

const BASE_USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const CARD_OWNER = '0xEaBF0A98aC208647247eAA25fDD4eB0e67793d61';
const CAD_CURRENCY = 0;
const ONE_CAD_E6 = 1_000_000n;
const DEFAULT_URI = 'https://api.beamio.io/metadata/{id}.json';

// 从 base-UserCardFactory.json 读取依赖
const deploymentsDir = path.join(__dirname, '..', 'deployments');
const factoryPath = path.join(deploymentsDir, 'base-UserCardFactory.json');
const data = JSON.parse(fs.readFileSync(factoryPath, 'utf8'));
const c = data.contracts?.beamioUserCardFactoryPaymaster;
const REDEEM_MODULE = c.redeemModule;
const QUOTE_HELPER = c.quoteHelper;
const DEPLOYER_ADDR = data.contracts?.beamioUserCardDeployer?.address || c.deployer;
const AA_FACTORY = c.aaFactory || '0xD86403DD1755F7add19540489Ea10cdE876Cc1CE';

async function main() {
  const master = JSON.parse(fs.readFileSync(process.env.HOME + '/.master.json', 'utf8'));
  const pk = (master.settle_contractAdmin[0] || '').startsWith('0x')
    ? master.settle_contractAdmin[0] : '0x' + master.settle_contractAdmin[0];

  const provider = new ethers.JsonRpcProvider(process.env.BASE_RPC_URL || 'https://1rpc.io/base');
  const wallet = new ethers.Wallet(pk, provider);
  console.log('Deployer:', wallet.address);

  // 1. 部署工厂
  const factoryArtifact = JSON.parse(fs.readFileSync(
    path.join(__dirname, '..', 'artifacts/src/BeamioUserCard/BeamioUserCardFactoryPaymasterV07.sol/BeamioUserCardFactoryPaymasterV07.json'),
    'utf8'
  ));
  const Factory = new ethers.ContractFactory(
    factoryArtifact.abi,
    factoryArtifact.bytecode,
    wallet
  );
  console.log('\n1. Deploying BeamioUserCardFactoryPaymasterV07...');
  const factory = await Factory.deploy(
    BASE_USDC,
    REDEEM_MODULE,
    QUOTE_HELPER,
    DEPLOYER_ADDR,
    AA_FACTORY,
    wallet.address
  );
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  console.log('   Factory:', factoryAddress);

  // 2. Deployer.setFactory
  const deployerAbi = ['function setFactory(address) external', 'function owner() view returns (address)'];
  const deployer = new ethers.Contract(DEPLOYER_ADDR, deployerAbi, wallet);
  const txSet = await deployer.setFactory(factoryAddress);
  await txSet.wait();
  console.log('   setFactory done');

  // 3. 部署 CCSA 卡
  const cardArtifact = JSON.parse(fs.readFileSync(
    path.join(__dirname, '..', 'artifacts/src/BeamioUserCard/BeamioUserCard.sol/BeamioUserCard.json'),
    'utf8'
  ));
  const initCode = cardArtifact.bytecode + ethers.AbiCoder.defaultAbiCoder()
    .encode(['string','uint8','uint256','address','address'],
      [DEFAULT_URI, CAD_CURRENCY, ONE_CAD_E6, CARD_OWNER, factoryAddress]).slice(2);

  const factoryCreateAbi = [
    'function createCardCollectionWithInitCode(address,uint8,uint256,bytes) external',
    'function cardsOfOwner(address) view returns (address[])',
    'event CardDeployed(address indexed cardOwner, address indexed card, uint8 currency, uint256 priceInCurrencyE6)',
  ];
  const factoryContract = new ethers.Contract(factoryAddress, factoryCreateAbi, wallet);
  const txCard = await factoryContract.createCardCollectionWithInitCode(
    CARD_OWNER, CAD_CURRENCY, ONE_CAD_E6, initCode
  );
  const receipt = await txCard.wait();
  let cardAddress;
  const iface = new ethers.Interface(factoryCreateAbi);
  for (const log of receipt.logs ?? []) {
    try {
      const p = iface.parseLog({ topics: log.topics, data: log.data });
      if (p?.name === 'CardDeployed') { cardAddress = p.args?.card ?? p.args?.[1]; break; }
    } catch {}
  }
  if (!cardAddress) {
    const cards = await factoryContract.cardsOfOwner(CARD_OWNER);
    cardAddress = cards[cards.length - 1];
  }
  console.log('\n2. CCSA card:', cardAddress);

  // 4. 保存部署信息
  const deploymentInfo = {
    network: 'base',
    chainId: '8453',
    deployer: wallet.address,
    timestamp: new Date().toISOString(),
    contracts: {
      beamioUserCardDeployer: { address: DEPLOYER_ADDR },
      beamioUserCardFactoryPaymaster: {
        address: factoryAddress,
        usdc: BASE_USDC,
        redeemModule: REDEEM_MODULE,
        quoteHelper: QUOTE_HELPER,
        deployer: DEPLOYER_ADDR,
        aaFactory: AA_FACTORY,
        owner: wallet.address,
        transactionHash: factory.deploymentTransaction?.hash,
      },
    },
  };
  fs.writeFileSync(factoryPath, JSON.stringify(deploymentInfo, null, 2));
  console.log('   Saved:', factoryPath);

  // 5. 更新 chainAddresses / config
  const newFactory = factoryAddress;
  const newCCSA = cardAddress;

  const files = [
    { p: 'src/x402sdk/src/chainAddresses.ts', updates: [
      [/BASE_CARD_FACTORY = '[^']+'/, `BASE_CARD_FACTORY = '${newFactory}'`],
      [/BASE_CCSA_CARD_ADDRESS = '[^']+'/, `BASE_CCSA_CARD_ADDRESS = '${newCCSA}'`],
    ]},
    { p: 'config/base-addresses.ts', updates: [
      [/CARD_FACTORY: '[^']+'/, `CARD_FACTORY: '${newFactory}'`],
    ]},
    { p: 'src/SilentPassUI/src/config/chainAddresses.ts', updates: [
      [/CARD_FACTORY: '[^']+'/, `CARD_FACTORY: '${newFactory}'`],
      [/BeamioCardCCSA_ADDRESS: '[^']+'/, `BeamioCardCCSA_ADDRESS: '${newCCSA}'`],
    ]},
    { p: 'src/SilentPassUI/src/services/beamio.ts', updates: [
      [/const BASE_CARD_FACTORY = '[^']+'/, `const BASE_CARD_FACTORY = '${newFactory}'`],
    ]},
  ];

  const root = path.join(__dirname, '..');
  for (const { p: rel, updates } of files) {
    const fp = path.join(root, rel);
    if (!fs.existsSync(fp)) continue;
    let content = fs.readFileSync(fp, 'utf8');
    for (const [re, replacement] of updates) {
      content = content.replace(re, replacement);
    }
    fs.writeFileSync(fp, content);
    console.log('   Updated:', rel);
  }

  // base-addresses.json
  const cfgJson = path.join(root, 'config/base-addresses.json');
  if (fs.existsSync(cfgJson)) {
    const j = JSON.parse(fs.readFileSync(cfgJson, 'utf8'));
    j.CARD_FACTORY = newFactory;
    fs.writeFileSync(cfgJson, JSON.stringify(j, null, 2));
    console.log('   Updated: config/base-addresses.json');
  }

  // deployments/base-UserCard-0xEaBF0A98.json
  const cardDeployPath = path.join(root, 'deployments/base-UserCard-0xEaBF0A98.json');
  fs.writeFileSync(cardDeployPath, JSON.stringify({
    network: 'base',
    chainId: '8453',
    eoa: CARD_OWNER,
    userCard: newCCSA,
    factory: newFactory,
    uri: DEFAULT_URI,
    currency: CAD_CURRENCY,
    price6: '1000000',
    timestamp: new Date().toISOString(),
    txHash: receipt.hash,
    note: 'New infrastructure with executeForAdmin',
  }, null, 2));
  console.log('   Updated: deployments/base-UserCard-0xEaBF0A98.json');

  console.log('\n=== Done ===');
  console.log('Factory:', newFactory);
  console.log('CCSA:', newCCSA);
}

main().catch(e => { console.error(e); process.exit(1); });
