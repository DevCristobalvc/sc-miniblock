import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

const STAKE = ethers.parseUnits("0.1", 18); // 0.10 token units
const DAY   = 86_400;

describe("MiniBlock", () => {
  async function deploy() {
    const [owner, p1, p2, p3, p4, p5] = await ethers.getSigners();

    // Deploy a mock ERC-20 as cUSD stand-in
    const Token = await ethers.getContractFactory("MockERC20");
    const token = await Token.deploy("Mock cUSD", "cUSD", 18);

    // Mint to players
    for (const p of [p1, p2, p3, p4, p5]) {
      await token.mint(p.address, ethers.parseUnits("100", 18));
    }

    const MiniBlock = await ethers.getContractFactory("MiniBlock");
    const mb = await MiniBlock.deploy(owner.address);

    return { mb, token, owner, p1, p2, p3, p4, p5 };
  }

  // ── FREE MODE ──────────────────────────────────────────────────────────────

  describe("Free mode", () => {
    it("stores a score", async () => {
      const { mb, p1 } = await loadFixture(deploy);
      await mb.connect(p1).submitFreeScore(150, 15, 4);
      const s = await mb.freeScores(p1.address);
      expect(s.score).to.equal(150);
    });

    it("only updates if new score is higher", async () => {
      const { mb, p1 } = await loadFixture(deploy);
      await mb.connect(p1).submitFreeScore(100, 10, 2);
      await mb.connect(p1).submitFreeScore(80,  8,  1);
      const s = await mb.freeScores(p1.address);
      expect(s.score).to.equal(100);
    });

    it("tracks scorer count", async () => {
      const { mb, p1, p2 } = await loadFixture(deploy);
      await mb.connect(p1).submitFreeScore(100, 10, 2);
      await mb.connect(p2).submitFreeScore(200, 20, 6);
      expect(await mb.freeScorersCount()).to.equal(2);
    });
  });

  // ── SESSION LIFECYCLE ──────────────────────────────────────────────────────

  describe("Session lifecycle", () => {
    it("creates a session", async () => {
      const { mb, token, owner } = await loadFixture(deploy);
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);
      const s = await mb.sessions(0);
      expect(s.token).to.equal(await token.getAddress());
      expect(s.stakeAmount).to.equal(STAKE);
    });

    it("players can join and submit scores", async () => {
      const { mb, token, owner, p1, p2 } = await loadFixture(deploy);
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);

      await token.connect(p1).approve(addr, STAKE);
      await token.connect(p2).approve(addr, STAKE);
      await mb.connect(p1).joinSession(0);
      await mb.connect(p2).joinSession(0);

      await mb.connect(p1).submitSessionScore(0, 250, 8);
      await mb.connect(p2).submitSessionScore(0, 180, 3);

      const e1 = await mb.getPlayerEntry(0, p1.address);
      expect(e1.score).to.equal(250);
    });

    it("cannot join twice", async () => {
      const { mb, token, owner, p1 } = await loadFixture(deploy);
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);
      await token.connect(p1).approve(addr, STAKE * 2n);
      await mb.connect(p1).joinSession(0);
      await expect(mb.connect(p1).joinSession(0)).to.be.revertedWith("already joined");
    });
  });

  // ── FINALIZATION & PAYOUTS ─────────────────────────────────────────────────

  describe("Finalization", () => {
    async function sessionWithPlayers() {
      const f = await loadFixture(deploy);
      const { mb, token, owner, p1, p2, p3, p4, p5 } = f;
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);

      const players = [p1, p2, p3, p4, p5];
      const scores  = [300, 250, 200, 150, 100];
      for (let i = 0; i < players.length; i++) {
        await token.connect(players[i]).approve(addr, STAKE);
        await mb.connect(players[i]).joinSession(0);
        await mb.connect(players[i]).submitSessionScore(0, scores[i], 0);
      }

      await time.increase(DAY + 1);
      return f;
    }

    it("finalizes and pays out correctly", async () => {
      const { mb, token, owner, p1, p2, p3 } = await sessionWithPlayers();

      const ownerBefore = await token.balanceOf(owner.address);
      await mb.finalizeSession(0);
      const ownerAfter = await token.balanceOf(owner.address);

      // Owner received 5% fee
      const pool    = STAKE * 5n;
      const fee     = pool * 500n / 10_000n;
      expect(ownerAfter - ownerBefore).to.equal(fee);

      // Top 3 of 5 paid (ceil(5*0.6)=3)
      const e1 = await mb.getPlayerEntry(0, p1.address);
      const e2 = await mb.getPlayerEntry(0, p2.address);
      const e3 = await mb.getPlayerEntry(0, p3.address);
      expect(e1.payout).to.be.gt(e2.payout);
      expect(e2.payout).to.be.gt(e3.payout);
      expect(e3.payout).to.be.gt(0n);

      // p4 and p5 get nothing
      const e4 = await mb.getPlayerEntry(0, (await ethers.getSigners())[4].address);
      expect(e4.payout).to.equal(0n);
    });

    it("total payouts + fee = total pool", async () => {
      const { mb, token, p1, p2, p3, p4, p5 } = await sessionWithPlayers();
      await mb.finalizeSession(0);

      const session = await mb.sessions(0);
      const pool    = session.totalPool;
      const fee     = session.platformFee;

      const payoutSum = (await Promise.all(
        [p1, p2, p3, p4, p5].map(p => mb.getPlayerEntry(0, p.address).then(e => e.payout))
      )).reduce((a, b) => a + b, 0n);

      // Allow 1 wei rounding error
      expect(payoutSum + fee).to.be.closeTo(pool, 1n);
    });

    it("players can claim payouts", async () => {
      const { mb, token, p1 } = await sessionWithPlayers();
      await mb.finalizeSession(0);

      const before = await token.balanceOf(p1.address);
      await mb.connect(p1).claimPayout(0);
      const after  = await token.balanceOf(p1.address);

      const e = await mb.getPlayerEntry(0, p1.address);
      expect(after - before).to.equal(e.payout);
      expect(e.claimed).to.be.true;
    });

    it("cannot claim twice", async () => {
      const { mb, p1 } = await sessionWithPlayers();
      await mb.finalizeSession(0);
      await mb.connect(p1).claimPayout(0);
      await expect(mb.connect(p1).claimPayout(0)).to.be.revertedWith("already claimed");
    });

    it("cannot finalize before end time", async () => {
      const { mb, token, owner, p1 } = await loadFixture(deploy);
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);
      await token.connect(p1).approve(addr, STAKE);
      await mb.connect(p1).joinSession(0);
      await expect(mb.finalizeSession(0)).to.be.revertedWith("not ended yet");
    });
  });

  // ── CANCELLATION ──────────────────────────────────────────────────────────

  describe("Cancellation", () => {
    it("owner can cancel and players get refund", async () => {
      const { mb, token, owner, p1 } = await loadFixture(deploy);
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);
      await token.connect(p1).approve(addr, STAKE);
      await mb.connect(p1).joinSession(0);

      const before = await token.balanceOf(p1.address);
      await mb.connect(owner).cancelSession(0);
      await mb.connect(p1).refundStake(0);
      const after = await token.balanceOf(p1.address);

      expect(after - before).to.equal(STAKE);
    });
  });

  // ── PREVIEW ────────────────────────────────────────────────────────────────

  describe("previewPayouts", () => {
    it("returns sorted players with estimated payouts", async () => {
      const { mb, token, owner, p1, p2 } = await loadFixture(deploy);
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);

      await token.connect(p1).approve(addr, STAKE);
      await token.connect(p2).approve(addr, STAKE);
      await mb.connect(p1).joinSession(0);
      await mb.connect(p2).joinSession(0);
      await mb.connect(p1).submitSessionScore(0, 100, 2);
      await mb.connect(p2).submitSessionScore(0, 300, 8);

      const [players, scores, payouts] = await mb.previewPayouts(0);
      // p2 should be rank 1 (higher score)
      expect(players[0]).to.equal(p2.address);
      expect(scores[0]).to.equal(300);
      expect(payouts[0]).to.be.gt(payouts[1]);
    });
  });
});
