// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title MiniBlock
 * @notice Stack-game leaderboard + Proof-of-Stack prize pool on Celo.
 *
 * SCORE VERIFICATION
 *   Stake-mode scores require an ECDSA signature from `scoreSigner`
 *   (the game backend). The signed message is:
 *     keccak256(abi.encodePacked(sessionId, player, score, perfectCount, nonce))
 *   Each nonce is single-use, preventing replay attacks.
 *   Free-mode scores are open (no funds at risk).
 *
 * PAYOUT FORMULA  (n ≥ 2 players)
 *   paidCount  = max(1, ceil(n × 0.6))
 *   weights[i] = paidCount − i   (rank 1 → paidCount, last paid → 1)
 *   totalW     = paidCount × (paidCount + 1) / 2
 *   payout[i]  = distributable × weights[i] / totalW
 *   Rounding dust (< 1 wei per player) goes to rank #1.
 *
 * EDGE CASES
 *   0 players → finalize is a no-op
 *   1 player  → full refund, no fee (no competition happened)
 *   n players, tied score → earlier joiner ranked higher (insertion sort stable)
 */
contract MiniBlock is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 public constant PLATFORM_FEE_BPS = 500;    // 5 %
    uint256 public constant BPS_BASE         = 10_000;
    uint256 public constant PAID_PCT_BPS     = 6_000;  // top 60 % paid
    uint32  public constant MAX_PLAYERS      = 100;    // gas safety for sort

    // ── Score signer (backend key) ────────────────────────────────────────────
    address public scoreSigner;

    event ScoreSignerUpdated(address indexed prev, address indexed next);

    // ── Free mode ─────────────────────────────────────────────────────────────
    struct FreeScore {
        uint32  score;
        uint16  blocksStacked;
        uint16  perfectCount;
        uint40  timestamp;
    }

    mapping(address => FreeScore) public freeScores;
    address[] public freeScorers;
    mapping(address => bool) private _hasFreeScore;

    event FreeScoreSubmitted(
        address indexed player,
        uint32 score,
        uint16 blocksStacked,
        uint16 perfectCount
    );

    // ── Stake sessions ────────────────────────────────────────────────────────
    enum SessionState { Open, Finalized, Cancelled }

    struct Session {
        address token;
        uint256 stakeAmount;
        uint64  startTime;
        uint64  endTime;
        SessionState state;
        uint256 totalPool;
        uint256 platformFee;
        uint32  playerCount;
    }

    struct PlayerEntry {
        uint256 stake;
        uint32  score;
        uint16  perfectCount;
        bool    scoreSubmitted;
        uint256 payout;
        bool    claimed;
    }

    uint256 public sessionCount;
    mapping(uint256 => Session)                          public sessions;
    mapping(uint256 => mapping(address => PlayerEntry))  public entries;
    mapping(uint256 => address[])                        public sessionPlayers;

    /// Nonces used for score signatures — prevents replay
    mapping(uint256 => bool) private _usedNonces;

    event SessionCreated(
        uint256 indexed sessionId,
        address token,
        uint256 stakeAmount,
        uint64  endTime,
        uint32  maxPlayers
    );
    event PlayerJoined(uint256 indexed sessionId, address indexed player);
    event ScoreSubmitted(
        uint256 indexed sessionId,
        address indexed player,
        uint32  score
    );
    event SessionFinalized(
        uint256 indexed sessionId,
        uint256 pool,
        uint256 fee,
        uint32  playerCount
    );
    event PayoutClaimed(
        uint256 indexed sessionId,
        address indexed player,
        uint256 amount
    );
    event SessionCancelled(uint256 indexed sessionId);

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor(address initialOwner, address initialSigner) Ownable(initialOwner) {
        scoreSigner = initialSigner;
    }

    function setScoreSigner(address next) external onlyOwner {
        emit ScoreSignerUpdated(scoreSigner, next);
        scoreSigner = next;
    }

    // ── FREE MODE ─────────────────────────────────────────────────────────────

    /// @notice Submit or update your free-mode best score (no funds, no verification).
    function submitFreeScore(
        uint32 score,
        uint16 blocksStacked,
        uint16 perfectCount
    ) external {
        FreeScore storage best = freeScores[msg.sender];
        if (score > best.score) {
            best.score         = score;
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
     * @param token       ERC-20 address (cUSD / cCOP)
     * @param stakeAmount Fixed stake per player (18-decimal units)
     * @param duration    Session length in seconds (min 60)
     */
    function createSession(
        address token,
        uint256 stakeAmount,
        uint64  duration
    ) external onlyOwner returns (uint256 sessionId) {
        require(token != address(0), "invalid token");
        require(stakeAmount > 0,     "stake must be > 0");
        require(duration >= 60,      "min 60s");

        sessionId = sessionCount++;
        uint64 endTime = uint64(block.timestamp) + duration;

        sessions[sessionId] = Session({
            token:       token,
            stakeAmount: stakeAmount,
            startTime:   uint64(block.timestamp),
            endTime:     endTime,
            state:       SessionState.Open,
            totalPool:   0,
            platformFee: 0,
            playerCount: 0
        });

        emit SessionCreated(sessionId, token, stakeAmount, endTime, MAX_PLAYERS);
    }

    /**
     * @notice Join an open session. Player must approve this contract first.
     */
    function joinSession(uint256 sessionId) external nonReentrant {
        Session storage s = sessions[sessionId];
        require(s.state == SessionState.Open,              "not open");
        require(block.timestamp < s.endTime,               "session ended");
        require(entries[sessionId][msg.sender].stake == 0, "already joined");
        require(s.playerCount < MAX_PLAYERS,               "session full");

        IERC20(s.token).safeTransferFrom(msg.sender, address(this), s.stakeAmount);

        entries[sessionId][msg.sender].stake = s.stakeAmount;
        sessionPlayers[sessionId].push(msg.sender);
        s.totalPool   += s.stakeAmount;
        s.playerCount += 1;

        emit PlayerJoined(sessionId, msg.sender);
    }

    /**
     * @notice Submit a backend-signed score for a stake session.
     * @param nonce   Unique value (use timestamp + random from backend)
     * @param sig     ECDSA signature by scoreSigner over
     *                keccak256(sessionId, player, score, perfectCount, nonce)
     */
    function submitSessionScore(
        uint256 sessionId,
        uint32  score,
        uint16  perfectCount,
        uint256 nonce,
        bytes calldata sig
    ) external {
        require(!_usedNonces[nonce], "nonce used");

        // Verify backend signature
        bytes32 msgHash = keccak256(
            abi.encodePacked(sessionId, msg.sender, score, perfectCount, nonce)
        ).toEthSignedMessageHash();
        require(msgHash.recover(sig) == scoreSigner, "invalid signature");

        _usedNonces[nonce] = true;

        Session storage s = sessions[sessionId];
        require(s.state == SessionState.Open, "not open");

        PlayerEntry storage e = entries[sessionId][msg.sender];
        require(e.stake > 0, "not a participant");

        if (score > e.score) {
            e.score          = score;
            e.perfectCount   = perfectCount;
            e.scoreSubmitted = true;
            emit ScoreSubmitted(sessionId, msg.sender, score);
        }
    }

    /**
     * @notice Finalize a session after endTime. Anyone can call.
     *
     * Edge cases:
     *   0 players → no-op
     *   1 player  → full refund, no fee
     *   n ≥ 2    → linear payout among top 60%, 5% fee to owner
     *
     * Dust: any wei left from integer division goes to rank #1.
     */
    function finalizeSession(uint256 sessionId) external nonReentrant {
        Session storage s = sessions[sessionId];
        require(s.state == SessionState.Open, "not open");
        require(block.timestamp >= s.endTime, "not ended");

        s.state = SessionState.Finalized;

        address[] storage players = sessionPlayers[sessionId];
        uint256 n = players.length;

        if (n == 0) {
            emit SessionFinalized(sessionId, 0, 0, 0);
            return;
        }

        // ── 1 player: full refund, no fee ────────────────────────────────────
        if (n == 1) {
            entries[sessionId][players[0]].payout = s.totalPool;
            emit SessionFinalized(sessionId, s.totalPool, 0, 1);
            return;
        }

        // ── n ≥ 2: sort, fee, linear payout ──────────────────────────────────

        // Insertion sort descending by score  O(n²), safe for n ≤ MAX_PLAYERS
        for (uint256 i = 1; i < n; i++) {
            address key      = players[i];
            uint32  keyScore = entries[sessionId][key].score;
            int256  j        = int256(i) - 1;
            while (j >= 0 && entries[sessionId][players[uint256(j)]].score < keyScore) {
                players[uint256(j + 1)] = players[uint256(j)];
                j--;
            }
            players[uint256(j + 1)] = key;
        }

        uint256 pool         = s.totalPool;
        uint256 fee          = (pool * PLATFORM_FEE_BPS) / BPS_BASE;
        uint256 distributable = pool - fee;
        s.platformFee        = fee;

        uint256 paidCount = (n * PAID_PCT_BPS + BPS_BASE - 1) / BPS_BASE;
        if (paidCount > n) paidCount = n;
        if (paidCount == 0) paidCount = 1;

        uint256 totalW = (paidCount * (paidCount + 1)) / 2;

        uint256 distributed;
        for (uint256 i = 0; i < paidCount; i++) {
            uint256 p = (distributable * (paidCount - i)) / totalW;
            entries[sessionId][players[i]].payout = p;
            distributed += p;
        }

        // Send rounding dust to rank #1
        if (distributed < distributable) {
            entries[sessionId][players[0]].payout += distributable - distributed;
        }

        if (fee > 0) {
            IERC20(s.token).safeTransfer(owner(), fee);
        }

        emit SessionFinalized(sessionId, pool, fee, uint32(n));
    }

    /// @notice Claim payout after finalization.
    function claimPayout(uint256 sessionId) external nonReentrant {
        require(sessions[sessionId].state == SessionState.Finalized, "not finalized");
        PlayerEntry storage e = entries[sessionId][msg.sender];
        require(e.stake > 0,  "not a participant");
        require(!e.claimed,   "already claimed");

        e.claimed     = true;
        uint256 amount = e.payout;
        if (amount > 0) {
            IERC20(sessions[sessionId].token).safeTransfer(msg.sender, amount);
        }
        emit PayoutClaimed(sessionId, msg.sender, amount);
    }

    /// @notice Owner cancels an open session; all players get full refund.
    function cancelSession(uint256 sessionId) external onlyOwner {
        require(sessions[sessionId].state == SessionState.Open, "not open");
        sessions[sessionId].state = SessionState.Cancelled;
        emit SessionCancelled(sessionId);
    }

    /// @notice Claim stake refund after cancellation.
    function refundStake(uint256 sessionId) external nonReentrant {
        require(sessions[sessionId].state == SessionState.Cancelled, "not cancelled");
        PlayerEntry storage e = entries[sessionId][msg.sender];
        require(e.stake > 0, "nothing to refund");
        require(!e.claimed,  "already refunded");

        e.claimed = true;
        IERC20(sessions[sessionId].token).safeTransfer(msg.sender, e.stake);
    }

    // ── VIEWS ─────────────────────────────────────────────────────────────────

    function getSessionPlayers(uint256 sessionId)
        external view returns (address[] memory)
    {
        return sessionPlayers[sessionId];
    }

    function getPlayerEntry(uint256 sessionId, address player)
        external view
        returns (uint256 stake, uint32 score, uint16 perfectCount, uint256 payout, bool claimed)
    {
        PlayerEntry storage e = entries[sessionId][player];
        return (e.stake, e.score, e.perfectCount, e.payout, e.claimed);
    }

    /// @notice Preview sorted payouts (read-only, does not mutate).
    function previewPayouts(uint256 sessionId)
        external view
        returns (address[] memory players, uint32[] memory scores, uint256[] memory payouts)
    {
        address[] storage sp = sessionPlayers[sessionId];
        uint256 n = sp.length;
        players = new address[](n);
        scores  = new uint32[](n);
        payouts = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            players[i] = sp[i];
            scores[i]  = entries[sessionId][sp[i]].score;
        }
        // Bubble sort (view only)
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (scores[j] > scores[i]) {
                    (players[i], players[j]) = (players[j], players[i]);
                    (scores[i],  scores[j])  = (scores[j],  scores[i]);
                }
            }
        }

        if (n <= 1) return (players, scores, payouts);

        uint256 pool         = sessions[sessionId].totalPool;
        uint256 distributable = pool - (pool * PLATFORM_FEE_BPS) / BPS_BASE;
        uint256 paidCount    = (n * PAID_PCT_BPS + BPS_BASE - 1) / BPS_BASE;
        if (paidCount > n) paidCount = n;
        if (paidCount == 0) paidCount = 1;
        uint256 totalW = (paidCount * (paidCount + 1)) / 2;

        uint256 distributed;
        for (uint256 i = 0; i < paidCount; i++) {
            uint256 p = (distributable * (paidCount - i)) / totalW;
            payouts[i] = p;
            distributed += p;
        }
        if (distributed < distributable) payouts[0] += distributable - distributed;
    }

    /// @notice Helper to check if a nonce has been used.
    function isNonceUsed(uint256 nonce) external view returns (bool) {
        return _usedNonces[nonce];
    }
}
