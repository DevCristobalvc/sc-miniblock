import { ethers, network } from "hardhat";

// Token addresses
const TOKENS = {
  alfajores: {
    cUSD: "0x874069Fa1Eb16D44d622F2e0Ca25eeA172369bC1",
    cCOP: "0x3a0EA4e0806805527C750ab9b34382642448468d", // Mento cCOP testnet
  },
  celo: {
    cUSD: "0x765DE816845861e75A25fCA122bb6898B8B1282a",
    cCOP: "0x8A567e2aE79CA692Bd748aB832081C45de4041eA", // Mento cCOP mainnet
  },
} as const;

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying MiniBlock with:", deployer.address);
  console.log("Network:", network.name);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Balance:", ethers.formatEther(balance), "CELO");

  // SCORE_SIGNER: backend wallet that signs game results.
  // Set SCORE_SIGNER in .env or pass as arg. Defaults to deployer for testnet.
  const scoreSigner = process.env.SCORE_SIGNER ?? deployer.address;
  console.log("Score signer:", scoreSigner);

  const MiniBlock = await ethers.getContractFactory("MiniBlock");
  const miniBlock = await MiniBlock.deploy(deployer.address, scoreSigner);
  await miniBlock.waitForDeployment();

  const address = await miniBlock.getAddress();
  console.log("\n✓ MiniBlock deployed to:", address);

  const net = network.name as keyof typeof TOKENS;
  if (TOKENS[net]) {
    console.log("\nToken addresses for this network:");
    console.log("  cUSD:", TOKENS[net].cUSD);
    console.log("  cCOP:", TOKENS[net].cCOP);
    console.log("\nTo create a test session (24h, 0.10 cUSD stake):");
    console.log(`  await miniBlock.createSession("${TOKENS[net].cUSD}", ethers.parseUnits("0.1", 18), 86400)`);
  }

  console.log("\nVerify on CeloScan:");
  console.log(`  npx hardhat verify --network ${network.name} ${address} ${deployer.address}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
