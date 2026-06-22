// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MiniBlock
 * @notice Stack-game leaderboard + Proof-of-Stack prize pool on Celo.
 *
 * FREE MODE
 *   Anyone can submit a score. No funds involved. Used for the global
 *   leaderboard. Anti-cheat is left to the frontend / future oracle.
 *
 * STAKE MODE (Sessions)
 *   1. Owner opens a Session (duration, token, stake amount).
 *   2. Players call joinSession() — transfers stakeAmount from player.
 *   3. Players call submitSessionScore() with their result.
 *      Each player can submit once; the highest score is kept.
 *   4. After the session ends, anyone calls finalizeSession().
 *      Payouts are calculated linearly among the top ~60% of stakers.
 *      Platform takes PLATFORM_FEE_BPS (500 = 5%).
 *   5. Players call claimPayout() to withdraw their share.
 *
 * PAYOUT FORMULA
 *   paidCount  = max(1, ceil(numPlayers * 0.6))
 *   weights[i] = paidCount - i   (rank 1 → paidCount, last paid → 1)
 *   totalW     = paidCount * (paidCount + 1) / 2
 *   payout[i]  = pool * weights[i] / totalW
 */
contract MiniBlock is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 public constant PLATFORM_FEE_BPS = 500; // 5%
    uint256 public constant BPS_BASE          = 10_000;
    /// Paid positions = ceil(numPlayers * PAID_PCT_BPS / BPS_BASE)
    uint256 public constant PAID_PCT_BPS      = 6_000; // 60%

    // ── Free mode ─────────────────────────────────────────────────────────────
    struct FreeScore {
        uint32  score;
        uint16  blocksStacked;
        uint16  perfectCount;
        uint40  timestamp;
    }

    /// wallet → best free-mode score
    mapping(address => FreeScore) public freeScores;

    /// All wallets that have ever submitted (for off-chain enumeration)
    address[] public freeScorers;
    mapping(address => bool) private _hasFreeScore;

    event FreeScoreSubmitted(address indexed player, uint32 score, uint16 blocksStacked, uint16 perfectCount);

    // ── Stake sessions ────────────────────────────────────────────────────────
    enum SessionState { Open, Finalized, Cancelled }

    struct Session {
        address token;          // cUSD or cCOP ERC-20
        uint256 stakeAmount;    // fixed stake per player
        uint64  startTime;
        uint64  endTime;
        SessionState state;
        uint256 totalPool;      // sum of all stakes
        uint256 platformFee;    // deducted at finalization
        uint32  playerCount;
    }

    struct PlayerEntry {
        uint256 stake;          // amount staked (0 = not joined)
        uint32  score;
        uint16  perfectCount;
        bool    scoreSubmitted;
        uint256 payout;         // set at finalization
        bool    claimed;
    }

    uint256 public sessionCount;
    mapping(uint256 => Session) public sessions;
    /// sessionId → player → entry
    mapping(uint256 => mapping(address => PlayerEntry)) public entries;
    /// sessionId → ranked list of players (sorted after finalization)
    mapping(uint256 => address[]) public sessionPlayers;

    event SessionCreated(uint256 indexed sessionId, address token, uint256 stakeAmount, uint64 endTime);
    event PlayerJoined(uint256 indexed sessionId, address indexed player);
    event ScoreSubmitted(uint256 indexed sessionId, address indexed player, uint32 score);
    event SessionFinalized(uint256 indexed sessionId, uint256 pool, uint256 fee, uint32 playerCount);
    event PayoutClaimed(uint256 indexed sessionId, address indexed player, uint256 amount);
    event SessionCancelled(uint256 indexed sessionId);

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor(address initialOwner) Ownable(initialOwner) {}

    // ── FREE MODE ─────────────────────────────────────────────────────────────

    /**
     * @notice Submit or update your free-mode score. Only stored if higher.
     */
    function submitFreeScore(
        uint32 score,
        uint16 blocksStacked,
        uint16 perfectCount
    ) external {
        FreeScore storage best = freeScores[msg.sender];

        if (score > best.score) {
            best.score        = score;
            best.blocksStacked = blocksStacked;
            best.perfectCount  = perfectCount;
            best.timestamp     = uint40(block.timestamp);

            if (!_hasFreeScore[msg.sender]) {
                _hasFreeScore[msg.sender] = true;
                freeScorers.push(msg.sender);
            }

            emit FreeScoreSubmitted(msg.sender, score, blocksStacked, perfectCount);
        }
    }

    function freeScorersCount() external view returns (uint256) {
        return freeScorers.length;
    }

    // ── SESSION MANAGEMENT ────────────────────────────────────────────────────

    /**
     * @notice Owner creates a new competitive session.
     * @param token       ERC-20 token address (cUSD, cCOP, etc.)
     * @param stakeAmount Fixed stake every player must pay
     * @param duration    Session length in seconds (e.g. 86400 for 24h)
     */
    function createSession(
        address token,
        uint256 stakeAmount,
        uint64  duration
    ) external onlyOwner returns (uint256 sessionId) {
        require(token != address(0),   "invalid token");
        require(stakeAmount > 0,       "stake must be > 0");
        require(duration >= 60,        "min 60s duration");

        sessionId = sessionCount++;
        sessions[sessionId] = Session({
            token:        token,
            stakeAmount:  stakeAmount,
            startTime:    uint64(block.timestamp),
            endTime:      uint64(block.timestamp) + duration,
            state:        SessionState.Open,
            totalPool:    0,
            platformFee:  0,
            playerCount:  0
        });

        emit SessionCreated(sessionId, token, stakeAmount, uint64(block.timestamp) + duration);
    }

    /**
     * @notice Join an open session by staking the required amount.
     *         Player must approve this contract first.
     */
    function joinSession(uint256 sessionId) external nonReentrant {
        Session storage s = sessions[sessionId];
        require(s.state == SessionState.Open,         "session not open");
        require(block.timestamp < s.endTime,           "session ended");
        require(entries[sessionId][msg.sender].stake == 0, "already joined");

        IERC20(s.token).safeTransferFrom(msg.sender, address(this), s.stakeAmount);

        entries[sessionId][msg.sender].stake = s.stakeAmount;
        sessionPlayers[sessionId].push(msg.sender);
        s.totalPool   += s.stakeAmount;
        s.playerCount += 1;

        emit PlayerJoined(sessionId, msg.sender);
    }

    /**
     * @notice Submit your score for a session you joined.
     *         Can be called multiple times; only the highest score is kept.
     */
    function submitSessionScore(
        uint256 sessionId,
        uint32  score,
        uint16  perfectCount
    ) external {
        Session storage s = sessions[sessionId];
        require(s.state == SessionState.Open,               "session not open");
        PlayerEntry storage e = entries[sessionId][msg.sender];
        require(e.stake > 0,                                "not a participant");

        if (score > e.score) {
            e.score          = score;
            e.perfectCount   = perfectCount;
            e.scoreSubmitted = true;
            emit ScoreSubmitted(sessionId, msg.sender, score);
        }
    }

    /**
     * @notice Finalize a session after it ends. Anyone can call this.
     *         Sorts players by score, calculates linear payouts, takes fee.
     */
    function finalizeSession(uint256 sessionId) external nonReentrant {
        Session storage s = sessions[sessionId];
        require(s.state == SessionState.Open,  "not open");
        require(block.timestamp >= s.endTime,  "not ended yet");

        s.state = SessionState.Finalized;

        address[] storage players = sessionPlayers[sessionId];
        uint256 n = players.length;

        if (n == 0) {
            // No players — nothing to distribute
            emit SessionFinalized(sessionId, 0, 0, 0);
            return;
        }

        // ── Sort by score (insertion sort — safe for expected small n ≤ 500) ──
        for (uint256 i = 1; i < n; i++) {
            address key = players[i];
            uint32  keyScore = entries[sessionId][key].score;
            int256  j = int256(i) - 1;
            while (j >= 0 && entries[sessionId][players[uint256(j)]].score < keyScore) {
                players[uint256(j + 1)] = players[uint256(j)];
                j--;
            }
            players[uint256(j + 1)] = key;
        }

        // ── Platform fee ──────────────────────────────────────────────────────
        uint256 pool = s.totalPool;
        uint256 fee  = (pool * PLATFORM_FEE_BPS) / BPS_BASE;
        uint256 distributable = pool - fee;
        s.platformFee = fee;

        // ── Paid positions ────────────────────────────────────────────────────
        // paidCount = max(1, ceil(n * 60 / 100))
        uint256 paidCount = (n * PAID_PCT_BPS + BPS_BASE - 1) / BPS_BASE;
        if (paidCount > n) paidCount = n;
        if (paidCount == 0) paidCount = 1;

        // weights: paidCount, paidCount-1, ..., 1
        // totalW  = paidCount*(paidCount+1)/2
        uint256 totalW = (paidCount * (paidCount + 1)) / 2;

        for (uint256 i = 0; i < paidCount; i++) {
            uint256 weight = paidCount - i;
            entries[sessionId][players[i]].payout = (distributable * weight) / totalW;
        }

        // Transfer fee to owner
        if (fee > 0) {
            IERC20(s.token).safeTransfer(owner(), fee);
        }

        emit SessionFinalized(sessionId, pool, fee, uint32(n));
    }

    /**
     * @notice Claim your payout after a session is finalized.
     */
    function claimPayout(uint256 sessionId) external nonReentrant {
        Session storage s = sessions[sessionId];
        require(s.state == SessionState.Finalized, "not finalized");
        PlayerEntry storage e = entries[sessionId][msg.sender];
        require(e.stake > 0,    "not a participant");
        require(!e.claimed,     "already claimed");

        e.claimed = true;
        uint256 amount = e.payout;

        if (amount > 0) {
            IERC20(s.token).safeTransfer(msg.sender, amount);
        }

        emit PayoutClaimed(sessionId, msg.sender, amount);
    }

    /**
     * @notice Cancel a session (only owner, only if Open).
     *         All stakers can claim their stake back.
     */
    function cancelSession(uint256 sessionId) external onlyOwner {
        Session storage s = sessions[sessionId];
        require(s.state == SessionState.Open, "not open");
        s.state = SessionState.Cancelled;
        emit SessionCancelled(sessionId);
    }

    /**
     * @notice Refund stake after a cancelled session.
     */
    function refundStake(uint256 sessionId) external nonReentrant {
        Session storage s = sessions[sessionId];
        require(s.state == SessionState.Cancelled, "not cancelled");
        PlayerEntry storage e = entries[sessionId][msg.sender];
        require(e.stake > 0,  "nothing to refund");
        require(!e.claimed,   "already refunded");

        e.claimed = true;
        IERC20(s.token).safeTransfer(msg.sender, e.stake);
    }

    // ── VIEWS ─────────────────────────────────────────────────────────────────

    function getSessionPlayers(uint256 sessionId) external view returns (address[] memory) {
        return sessionPlayers[sessionId];
    }

    function getPlayerEntry(uint256 sessionId, address player)
        external view
        returns (uint256 stake, uint32 score, uint16 perfectCount, uint256 payout, bool claimed)
    {
        PlayerEntry storage e = entries[sessionId][player];
        return (e.stake, e.score, e.perfectCount, e.payout, e.claimed);
    }

    /// @notice Compute what the payout distribution would look like right now.
    function previewPayouts(uint256 sessionId)
        external view
        returns (address[] memory players, uint32[] memory scores, uint256[] memory payouts)
    {
        address[] storage sp = sessionPlayers[sessionId];
        uint256 n = sp.length;
        players  = new address[](n);
        scores   = new uint32[](n);
        payouts  = new uint256[](n);

        // Copy (don't mutate storage in a view)
        for (uint256 i = 0; i < n; i++) {
            players[i] = sp[i];
            scores[i]  = entries[sessionId][sp[i]].score;
        }

        // Bubble sort (view only — fine)
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (scores[j] > scores[i]) {
                    (players[i], players[j]) = (players[j], players[i]);
                    (scores[i],  scores[j])  = (scores[j],  scores[i]);
                }
            }
        }

        if (n == 0) return (players, scores, payouts);

        uint256 pool          = sessions[sessionId].totalPool;
        uint256 distributable = pool - (pool * PLATFORM_FEE_BPS) / BPS_BASE;
        uint256 paidCount     = (n * PAID_PCT_BPS + BPS_BASE - 1) / BPS_BASE;
        if (paidCount > n) paidCount = n;
        if (paidCount == 0) paidCount = 1;
        uint256 totalW = (paidCount * (paidCount + 1)) / 2;

        for (uint256 i = 0; i < paidCount; i++) {
            payouts[i] = (distributable * (paidCount - i)) / totalW;
        }
    }
}
