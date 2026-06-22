import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-network-helpers";

const STAKE = ethers.parseUnits("0.1", 18);
const DAY   = 86_400;

/** Sign a score with the signer wallet — mirrors what the backend does */
async function signScore(
  signer:       any,
  sessionId:    number,
  player:       string,
  score:        number,
  perfectCount: number,
  nonce:        number
): Promise<string> {
  const msg = ethers.solidityPackedKeccak256(
    ["uint256","address","uint32","uint16","uint256"],
    [sessionId, player, score, perfectCount, nonce]
  );
  return signer.signMessage(ethers.getBytes(msg));
}

describe("MiniBlock", () => {
  // ── Fixture ────────────────────────────────────────────────────────────────
  async function deploy() {
    const [owner, signer, p1, p2, p3, p4, p5] = await ethers.getSigners();

    const Token = await ethers.getContractFactory("MockERC20");
    const token = await Token.deploy("Mock cUSD", "cUSD", 18);

    for (const p of [p1, p2, p3, p4, p5]) {
      await token.mint(p.address, ethers.parseUnits("100", 18));
    }

    const MB = await ethers.getContractFactory("MiniBlock");
    const mb = await MB.deploy(owner.address, signer.address);

    return { mb, token, owner, signer, p1, p2, p3, p4, p5 };
  }

  /** Helper: open session + n players join + submit scores */
  async function sessionWith(
    n: number,
    scores: number[],
    opts?: { duration?: number }
  ) {
    const f = await loadFixture(deploy);
    const { mb, token, owner, signer } = f;
    const players = [f.p1, f.p2, f.p3, f.p4, f.p5].slice(0, n);
    const addr    = await mb.getAddress();
    const dur     = opts?.duration ?? DAY;

    await mb.connect(owner).createSession(await token.getAddress(), STAKE, dur);

    for (let i = 0; i < n; i++) {
      await token.connect(players[i]).approve(addr, STAKE);
      await mb.connect(players[i]).joinSession(0);
    }
    for (let i = 0; i < n; i++) {
      const nonce = i + 1;
      const sig   = await signScore(signer, 0, players[i].address, scores[i], 0, nonce);
      await mb.connect(players[i]).submitSessionScore(0, scores[i], 0, nonce, sig);
    }

    await time.increase(dur + 1);
    return { ...f, players };
  }

  // ── FREE MODE ──────────────────────────────────────────────────────────────
  describe("Free mode", () => {
    it("stores a score", async () => {
      const { mb, p1 } = await loadFixture(deploy);
      await mb.connect(p1).submitFreeScore(150, 15, 4);
      expect((await mb.freeScores(p1.address)).score).to.equal(150);
    });

    it("only updates if new score is higher", async () => {
      const { mb, p1 } = await loadFixture(deploy);
      await mb.connect(p1).submitFreeScore(100, 10, 2);
      await mb.connect(p1).submitFreeScore(80, 8, 1);
      expect((await mb.freeScores(p1.address)).score).to.equal(100);
    });

    it("tracks unique scorers", async () => {
      const { mb, p1, p2 } = await loadFixture(deploy);
      await mb.connect(p1).submitFreeScore(100, 10, 2);
      await mb.connect(p1).submitFreeScore(200, 20, 6); // same player, higher score
      await mb.connect(p2).submitFreeScore(50, 5, 0);
      expect(await mb.freeScorersCount()).to.equal(2);
    });
  });

  // ── SESSION LIFECYCLE ──────────────────────────────────────────────────────
  describe("Session lifecycle", () => {
    it("creates a session with correct params", async () => {
      const { mb, token, owner } = await loadFixture(deploy);
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);
      const s = await mb.sessions(0);
      expect(s.stakeAmount).to.equal(STAKE);
      expect(s.playerCount).to.equal(0);
    });

    it("players can join", async () => {
      const { mb, token, owner, p1 } = await loadFixture(deploy);
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);
      await token.connect(p1).approve(addr, STAKE);
      await mb.connect(p1).joinSession(0);
      expect((await mb.sessions(0)).playerCount).to.equal(1);
    });

    it("rejects double-join", async () => {
      const { mb, token, owner, p1 } = await loadFixture(deploy);
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);
      await token.connect(p1).approve(addr, STAKE * 2n);
      await mb.connect(p1).joinSession(0);
      await expect(mb.connect(p1).joinSession(0)).to.be.revertedWith("already joined");
    });

    it("rejects join after end time", async () => {
      const { mb, token, owner, p1 } = await loadFixture(deploy);
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, 60);
      await time.increase(61);
      await token.connect(p1).approve(addr, STAKE);
      await expect(mb.connect(p1).joinSession(0)).to.be.revertedWith("session ended");
    });
  });

  // ── SCORE SIGNATURE ────────────────────────────────────────────────────────
  describe("Score signature verification", () => {
    it("accepts a valid signature", async () => {
      const { mb, token, owner, signer, p1 } = await loadFixture(deploy);
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);
      await token.connect(p1).approve(addr, STAKE);
      await mb.connect(p1).joinSession(0);

      const sig = await signScore(signer, 0, p1.address, 250, 8, 42);
      await mb.connect(p1).submitSessionScore(0, 250, 8, 42, sig);
      expect((await mb.getPlayerEntry(0, p1.address)).score).to.equal(250);
    });

    it("rejects a wrong signer", async () => {
      const { mb, token, owner, p1, p2 } = await loadFixture(deploy);
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);
      await token.connect(p1).approve(addr, STAKE);
      await mb.connect(p1).joinSession(0);

      // p2 signs instead of the real signer
      const sig = await signScore(p2, 0, p1.address, 999, 0, 99);
      await expect(
        mb.connect(p1).submitSessionScore(0, 999, 0, 99, sig)
      ).to.be.revertedWith("invalid signature");
    });

    it("rejects a replayed nonce", async () => {
      const { mb, token, owner, signer, p1 } = await loadFixture(deploy);
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);
      await token.connect(p1).approve(addr, STAKE);
      await mb.connect(p1).joinSession(0);

      const sig = await signScore(signer, 0, p1.address, 100, 2, 7);
      await mb.connect(p1).submitSessionScore(0, 100, 2, 7, sig);

      const sig2 = await signScore(signer, 0, p1.address, 200, 4, 7); // same nonce
      await expect(
        mb.connect(p1).submitSessionScore(0, 200, 4, 7, sig2)
      ).to.be.revertedWith("nonce used");
    });
  });

  // ── EDGE CASE: 0 PLAYERS ──────────────────────────────────────────────────
  describe("Edge: 0 players", () => {
    it("finalizes empty session without revert", async () => {
      const { mb, token, owner } = await loadFixture(deploy);
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, 60);
      await time.increase(61);
      await expect(mb.finalizeSession(0)).to.not.be.reverted;
      expect((await mb.sessions(0)).state).to.equal(1 /* Finalized */);
    });
  });

  // ── EDGE CASE: 1 PLAYER ───────────────────────────────────────────────────
  describe("Edge: 1 player", () => {
    it("gives full refund with no fee", async () => {
      const { mb, token, owner, p1 } = await loadFixture(deploy);
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, 60);
      await token.connect(p1).approve(addr, STAKE);
      await mb.connect(p1).joinSession(0);

      await time.increase(61);
      const ownerBefore = await token.balanceOf(owner.address);
      await mb.finalizeSession(0);
      const ownerAfter = await token.balanceOf(owner.address);

      // No fee taken
      expect(ownerAfter).to.equal(ownerBefore);

      // Player gets full stake back
      const entry = await mb.getPlayerEntry(0, p1.address);
      expect(entry.payout).to.equal(STAKE);

      const balBefore = await token.balanceOf(p1.address);
      await mb.connect(p1).claimPayout(0);
      const balAfter = await token.balanceOf(p1.address);
      expect(balAfter - balBefore).to.equal(STAKE);
    });
  });

  // ── EDGE CASE: TIED SCORES ────────────────────────────────────────────────
  describe("Edge: tied scores", () => {
    it("first joiner ranked higher on tie", async () => {
      const f = await loadFixture(deploy);
      const { mb, token, owner, signer, p1, p2 } = f;
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, 60);

      for (const p of [p1, p2]) {
        await token.connect(p).approve(addr, STAKE);
        await mb.connect(p).joinSession(0);
      }

      // Same score
      const s1 = await signScore(signer, 0, p1.address, 100, 0, 1);
      const s2 = await signScore(signer, 0, p2.address, 100, 0, 2);
      await mb.connect(p1).submitSessionScore(0, 100, 0, 1, s1);
      await mb.connect(p2).submitSessionScore(0, 100, 0, 2, s2);

      await time.increase(61);
      await mb.finalizeSession(0);

      const [players] = await mb.previewPayouts(0);
      // p1 joined first → should appear at index 0 after stable sort
      // (both have score 100, insertion sort preserves original order)
      const e1 = await mb.getPlayerEntry(0, p1.address);
      const e2 = await mb.getPlayerEntry(0, p2.address);
      expect(e1.payout).to.be.gte(e2.payout);
    });
  });

  // ── FINALIZATION: MATH ────────────────────────────────────────────────────
  describe("Finalization math", () => {
    it("2 players: correct split, 5% fee", async () => {
      const f = await sessionWith(2, [300, 150]);
      const { mb, token, owner } = f;

      const ownerBefore = await token.balanceOf(owner.address);
      await mb.finalizeSession(0);
      const ownerAfter = await token.balanceOf(owner.address);

      const pool = STAKE * 2n;
      const fee  = pool * 500n / 10_000n;
      expect(ownerAfter - ownerBefore).to.equal(fee);

      // paidCount = ceil(2*0.6) = 2, weights=[2,1]
      const e1 = await mb.getPlayerEntry(0, f.players[0].address);
      const e2 = await mb.getPlayerEntry(0, f.players[1].address);
      expect(e1.payout).to.be.gt(e2.payout);
    });

    it("5 players: paid=3, bottom 2 get zero", async () => {
      const f = await sessionWith(5, [300, 250, 200, 150, 100]);
      const { mb } = f;
      await mb.finalizeSession(0);

      const e4 = await mb.getPlayerEntry(0, f.players[3].address);
      const e5 = await mb.getPlayerEntry(0, f.players[4].address);
      expect(e4.payout).to.equal(0);
      expect(e5.payout).to.equal(0);
    });

    it("total payouts + fee == total pool (no dust lost)", async () => {
      const f = await sessionWith(5, [300, 250, 200, 150, 100]);
      const { mb } = f;
      await mb.finalizeSession(0);

      const session  = await mb.sessions(0);
      const pool     = session.totalPool;
      const fee      = session.platformFee;

      let payoutSum = 0n;
      for (const p of f.players) {
        payoutSum += (await mb.getPlayerEntry(0, p.address)).payout;
      }
      expect(payoutSum + fee).to.equal(pool);
    });

    it("all players can claim", async () => {
      const f = await sessionWith(5, [300, 250, 200, 150, 100]);
      const { mb, token } = f;
      await mb.finalizeSession(0);

      for (const p of f.players) {
        const before  = await token.balanceOf(p.address);
        await mb.connect(p).claimPayout(0);
        const after   = await token.balanceOf(p.address);
        const entry   = await mb.getPlayerEntry(0, p.address);
        expect(after - before).to.equal(entry.payout);
      }
    });

    it("cannot finalize before endTime", async () => {
      const { mb, token, owner, p1 } = await loadFixture(deploy);
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);
      await token.connect(p1).approve(addr, STAKE);
      await mb.connect(p1).joinSession(0);
      await expect(mb.finalizeSession(0)).to.be.revertedWith("not ended");
    });

    it("cannot claim twice", async () => {
      const f = await sessionWith(2, [300, 100]);
      const { mb } = f;
      await mb.finalizeSession(0);
      await mb.connect(f.players[0]).claimPayout(0);
      await expect(mb.connect(f.players[0]).claimPayout(0)).to.be.revertedWith("already claimed");
    });
  });

  // ── MAX PLAYERS CAP ───────────────────────────────────────────────────────
  describe("MAX_PLAYERS cap", () => {
    it("reports MAX_PLAYERS = 100", async () => {
      const { mb } = await loadFixture(deploy);
      expect(await mb.MAX_PLAYERS()).to.equal(100);
    });
  });

  // ── CANCELLATION ──────────────────────────────────────────────────────────
  describe("Cancellation", () => {
    it("owner cancels → players get full refund", async () => {
      const { mb, token, owner, p1, p2 } = await loadFixture(deploy);
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);
      for (const p of [p1, p2]) {
        await token.connect(p).approve(addr, STAKE);
        await mb.connect(p).joinSession(0);
      }

      await mb.connect(owner).cancelSession(0);

      for (const p of [p1, p2]) {
        const before = await token.balanceOf(p.address);
        await mb.connect(p).refundStake(0);
        const after  = await token.balanceOf(p.address);
        expect(after - before).to.equal(STAKE);
      }
    });
  });

  // ── SCORE SIGNER MANAGEMENT ───────────────────────────────────────────────
  describe("Score signer management", () => {
    it("owner can update signer", async () => {
      const { mb, owner, p1 } = await loadFixture(deploy);
      await mb.connect(owner).setScoreSigner(p1.address);
      expect(await mb.scoreSigner()).to.equal(p1.address);
    });

    it("non-owner cannot update signer", async () => {
      const { mb, p1 } = await loadFixture(deploy);
      await expect(mb.connect(p1).setScoreSigner(p1.address)).to.be.reverted;
    });
  });

  // ── PREVIEW PAYOUTS ────────────────────────────────────────────────────────
  describe("previewPayouts", () => {
    it("returns players sorted by score with estimated payouts", async () => {
      const { mb, token, owner, signer, p1, p2 } = await loadFixture(deploy);
      const addr = await mb.getAddress();
      await mb.connect(owner).createSession(await token.getAddress(), STAKE, DAY);
      for (const p of [p1, p2]) {
        await token.connect(p).approve(addr, STAKE);
        await mb.connect(p).joinSession(0);
      }
      const s1 = await signScore(signer, 0, p1.address, 100, 2, 1);
      const s2 = await signScore(signer, 0, p2.address, 300, 8, 2);
      await mb.connect(p1).submitSessionScore(0, 100, 2, 1, s1);
      await mb.connect(p2).submitSessionScore(0, 300, 8, 2, s2);

      const [players, scores, payouts] = await mb.previewPayouts(0);
      expect(players[0]).to.equal(p2.address); // p2 has higher score
      expect(scores[0]).to.equal(300);
      expect(payouts[0]).to.be.gt(payouts[1]);
    });
  });
});
