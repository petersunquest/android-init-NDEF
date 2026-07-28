import { network as networkModule } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * 查询 EOA 地址是否存在 BeamioAccount 并返回账户地址
 * 
 * @param eoaAddress - EOA 地址
 * @param factoryAddress - Factory 合约地址（可选，会自动从部署记录读取）
 * @param accountIndex - 账户索引（默认 0，即主要账户）
 * @returns BeamioAccount 地址，如果不存在则返回 null
 */
export async function getBeamioAccount(
  eoaAddress: string,
  factoryAddress?: string,
  accountIndex: number = 0
): Promise<{ exists: boolean; address: string | null; isDeployed: boolean }> {
  const { ethers } = await networkModule.connect();
  const networkInfo = await ethers.provider.getNetwork();
  
  // 如果没有提供 Factory 地址，尝试从部署记录读取
  if (!factoryAddress) {
    const deploymentsDir = path.join(__dirname, "..", "..", "deployments");
    const configJsonFile = path.join(__dirname, "..", "..", "config", "base-addresses.json");
    const networkName = networkInfo.name;
    
    try {
      if (fs.existsSync(configJsonFile)) {
        const baseConfig = JSON.parse(fs.readFileSync(configJsonFile, "utf-8"));
        if (baseConfig.AA_FACTORY) {
          factoryAddress = baseConfig.AA_FACTORY;
          console.log(`✅ 从 config/base-addresses.json 读取 Factory 地址: ${factoryAddress}`);
        }
      }

      const factoryFile = path.join(deploymentsDir, `${networkName}-FactoryAndModule.json`);
      if (!factoryAddress && fs.existsSync(factoryFile)) {
        const factoryData = JSON.parse(fs.readFileSync(factoryFile, "utf-8"));
        if (factoryData.contracts?.beamioFactoryPaymaster?.address) {
          factoryAddress = factoryData.contracts.beamioFactoryPaymaster.address;
          console.log(`✅ 从部署记录读取 Factory 地址: ${factoryAddress}`);
        }
      }
    } catch (error) {
      console.log("⚠️  无法从部署记录读取 Factory 地址");
    }
  }
  
  if (!factoryAddress) {
    throw new Error("未提供 Factory 地址，且无法从部署记录读取。请提供 factoryAddress 参数。");
  }
  
  // 验证 EOA 地址格式
  if (!ethers.isAddress(eoaAddress)) {
    throw new Error(`无效的 EOA 地址: ${eoaAddress}`);
  }
  
  // 获取 Factory 合约实例
  const factory = await ethers.getContractAt("BeamioFactoryPaymasterV07", factoryAddress);
  
  // 方法 1: 查询主要账户（primaryAccountOf）
  try {
    const primaryAccount = await factory.beamioAccountOf(eoaAddress);
    if (primaryAccount && primaryAccount !== ethers.ZeroAddress) {
      // 检查账户是否已部署（有代码）
      const code = await ethers.provider.getCode(primaryAccount);
      const isDeployed = code !== "0x" && code.length > 2;
      
      return {
        exists: true,
        address: primaryAccount,
        isDeployed
      };
    }
  } catch (error) {
    console.log("⚠️  查询主要账户失败:", error);
  }
  
  // 方法 2: 直接使用 Deployer 计算地址（绕过 Factory.getAddress 的问题）
  try {
    const deployerAddress = await factory.deployer();
    const deployer = await ethers.getContractAt("BeamioAccountDeployer", deployerAddress);
    
    // 计算 salt
    const salt = await deployer.computeSalt(eoaAddress, accountIndex);
    
    // 构建 initCode（与 Factory._initCode() 相同）
    const ENTRY_POINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
    const BeamioAccountFactory = await ethers.getContractFactory("BeamioAccount");
    const deployTx = await BeamioAccountFactory.getDeployTransaction(ENTRY_POINT);
    const initCode = deployTx.data;
    
    if (initCode) {
      const computedAddress = await deployer.getAddress(salt, initCode);
      
      // 跳过异常结果（与 Factory 或 Deployer 地址相同）
      if (computedAddress.toLowerCase() === factoryAddress.toLowerCase() ||
          computedAddress.toLowerCase() === deployerAddress.toLowerCase()) {
        console.log("⚠️  计算的地址异常，跳过此方法");
      } else {
        const code = await ethers.provider.getCode(computedAddress);
        const isDeployed = code !== "0x" && code.length > 2;
        
        if (isDeployed) {
          // 验证是否是 BeamioAccount（检查 isBeamioAccount 映射）
          try {
            const isRegistered = await factory.isBeamioAccount(computedAddress);
            if (isRegistered) {
              return {
                exists: true,
                address: computedAddress,
                isDeployed: true
              };
            }
          } catch (error) {
            // 如果查询失败，仍然返回已部署的地址
          }
          
          // 如果账户已部署但未在 Factory 注册，仍然返回地址
          // （可能是通过其他方式部署的）
          return {
            exists: true,
            address: computedAddress,
            isDeployed: true
          };
        }
      }
    }
  } catch (error) {
    console.log("⚠️  使用 Deployer 计算地址失败:", error);
  }
  
  // 方法 3: 尝试查询多个索引的账户（使用 Deployer 直接计算）
  try {
    const deployerAddress = await factory.deployer();
    const deployer = await ethers.getContractAt("BeamioAccountDeployer", deployerAddress);
    const ENTRY_POINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
    const BeamioAccountFactory = await ethers.getContractFactory("BeamioAccount");
    const deployTx = await BeamioAccountFactory.getDeployTransaction(ENTRY_POINT);
    const initCode = deployTx.data;
    
    if (initCode) {
      for (let i = 0; i < 10; i++) {
        const salt = await deployer.computeSalt(eoaAddress, i);
        const computedAddress = await deployer.getAddress(salt, initCode);
        
        // 跳过异常结果
        if (computedAddress.toLowerCase() === factoryAddress.toLowerCase() ||
            computedAddress.toLowerCase() === deployerAddress.toLowerCase()) {
          continue;
        }
        
        const code = await ethers.provider.getCode(computedAddress);
        const isDeployed = code !== "0x" && code.length > 2;
        
        if (isDeployed) {
          try {
            const isRegistered = await factory.isBeamioAccount(computedAddress);
            if (isRegistered) {
              return {
                exists: true,
                address: computedAddress,
                isDeployed: true
              };
            }
          } catch (error) {
            // 忽略错误
          }
        }
      }
    }
  } catch (error) {
    // 忽略错误
  }
  
  return {
    exists: false,
    address: null,
    isDeployed: false
  };
}
