import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/**
 * Deploys MiniBlock contract.
 * The deployer wallet becomes the owner (receives platform fees, can create sessions).
 */
const MiniBlockModule = buildModule("MiniBlockModule", (m) => {
  const deployer = m.getAccount(0);

  const miniBlock = m.contract("MiniBlock", [deployer]);

  return { miniBlock };
});

export default MiniBlockModule;
