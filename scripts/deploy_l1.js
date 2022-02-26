const { ethers } = require("hardhat");
const { BigNumber } = require("@ethersproject/bignumber");
const verifyStr = "npx hardhat verify --network";

let signer;
let apeXToken;
let vipNft;
let squidNft;
let apeXToVipNFT = BigNumber.from("20833320000000000000000000");
let apeXToSquidNFT = BigNumber.from("20520000000000000000000000");

let vipNftName = "ApeX OG NFT";
let vipNftSymbol = "APEX-OG";
let vipNftBaseURI = "https://apex.mypinata.cloud/ipfs/Qmevfgfzbc7sLEZgQSmp9TSM7iTUffweG65qve25bwEsF1/";
let vipNftStartTime = 1678262400;
let vipNftCliff = (365 * 24 * 3600) / 2;
let vipNftDuration = 365 * 24 * 3600;

let squidNftName = "ApeX Predator NFT";
let squidNftSymbol = "APEX-PRD";
let squidNftBaseURI = "https://apex.mypinata.cloud/ipfs/QmapaMVk6Zw6ieFgE9442d6g2i9LVFPMsM1xR51EzZ1nbC/";
let squidNftStartTime = 1646726400;
let squidNftEndTime = 1646985600;
let squidStartTime = 1678262400;

let genesisNftName = "ApeX Genesis NFT";
let genesisNftSymbol = "APEX-GNS";
let genesisNftBaseURI = "https://gateway.pinata.cloud/ipfs/QmPdTKdcm9KNHpS6jYFX2P2SyGeF5xcrw7MAWZFeVM4YgC/";

const main = async () => {
  const accounts = await hre.ethers.getSigners();
  signer = accounts[0].address;
  await createApeXToken();
  await createVipNft();
  await createNftSquid();
  // await createGenesisNFT();
  await createMulticall2();
};

async function createApeXToken() {
  const ApeXToken = await ethers.getContractFactory("ApeXToken");
  apeXToken = await ApeXToken.deploy();
  console.log("ApeXToken:", apeXToken.address);
  console.log(verifyStr, process.env.HARDHAT_NETWORK, apeXToken.address);
}

async function createVipNft() {
  if (apeXToken == null) {
    let apeXTokenAddress = "0xF9546a61548602aFfA721d32597326eE4AdD3e55";
    const ApeXToken = await ethers.getContractFactory("ApeXToken");
    apeXToken = await ApeXToken.attach(apeXTokenAddress);
  }
  const ApeXVIPNFT = await ethers.getContractFactory("ApeXVIPNFT");
  vipNft = await ApeXVIPNFT.deploy(
    vipNftName,
    vipNftSymbol,
    vipNftBaseURI,
    apeXToken.address,
    vipNftStartTime,
    vipNftCliff,
    vipNftDuration
  );
  console.log("ApeXVIPNFT:", vipNft.address);
  console.log(
    verifyStr,
    process.env.HARDHAT_NETWORK,
    vipNft.address,
    vipNftName,
    vipNftSymbol,
    vipNftBaseURI,
    apeXToken.address,
    vipNftStartTime,
    vipNftCliff,
    vipNftDuration
  );

  // await apeXToken.transfer(vipNft.address, apeXToVipNFT);
  // let balanceInVip = await apeXToken.balanceOf(vipNft.address);
  // console.log("ApeX in VIPNFT:", balanceInVip.toString());
}

async function createNftSquid() {
  if (apeXToken == null) {
    let apeXTokenAddress = "0xF9546a61548602aFfA721d32597326eE4AdD3e55";
    const ApeXToken = await ethers.getContractFactory("ApeXToken");
    apeXToken = await ApeXToken.attach(apeXTokenAddress);
  }
  const NftSquid = await ethers.getContractFactory("NftSquid");
  squidNft = await NftSquid.deploy(
    squidNftName,
    squidNftSymbol,
    squidNftBaseURI,
    apeXToken.address,
    squidNftStartTime,
    squidNftEndTime
  );
  await squidNft.setSquidStartTime(squidStartTime);
  console.log("NftSquid:", squidNft.address);
  console.log(
    verifyStr,
    process.env.HARDHAT_NETWORK,
    squidNft.address,
    squidNftName,
    squidNftSymbol,
    squidNftBaseURI,
    apeXToken.address,
    squidNftStartTime,
    squidNftEndTime
  );

  // await apeXToken.transfer(squidNft.address, apeXToSquidNFT);
  // let balance = await apeXToken.balanceOf(squidNft.address);
  // console.log("ApeX in SquidNft:", balance.toString());
}

async function createGenesisNFT() {
  const GenesisNFT = await ethers.getContractFactory("GenesisNFT");
  let genesisNFT = await GenesisNFT.deploy(genesisNftName, genesisNftSymbol, genesisNftBaseURI);
  await genesisNFT.mint(signer);
  console.log("GenesisNFT:", genesisNFT.address);
  console.log(verifyStr, process.env.HARDHAT_NETWORK, genesisNFT.address);
}

async function createMulticall2() {
  const Multicall2 = await ethers.getContractFactory("Multicall2");
  let multicall2 = await Multicall2.deploy();
  console.log("Multicall2:", multicall2.address);
  console.log(verifyStr, process.env.HARDHAT_NETWORK, multicall2.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
