// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title NousCore — Thought marketplace with wisdom incentive loop.
/// @notice Three mechanisms close the loop:
///   1. Questioner royalty (10%) — good questions earn ongoing revenue
///   2. Reputation flywheel — unlock count = on-chain reputation = pricing power
///   3. Citation royalty (5%) — knowledge builds on knowledge, cited authors earn
contract NousCore is Pausable, ReentrancyGuard, Ownable {
    uint256 public constant MIN_STAKE = 0.01 ether;
    uint256 public constant SLASH_WINDOW = 30 days;
    uint256 public constant EXTEND_WINDOW = 90 days;
    uint256 public constant EXTEND_COST_BPS = 5000;

    // Fee split (basis points, total = 10000)
    uint256 public constant AUTHOR_BPS = 8000;     // 80% to answer author
    uint256 public constant QUESTIONER_BPS = 1000;  // 10% to question author
    uint256 public constant CITATION_BPS = 500;     // 5% to cited answer author
    uint256 public constant PLATFORM_BPS = 500;     // 5% to platform

    struct Question {
        address author;
        bytes32 contentHash;
        uint256 stake;
        uint48 createdAt;
        uint48 deadline;
        bool extended;
        bool slashed;
        uint32 unlockCount;  // total unlocks across all answers
        uint32 voteCount;
    }

    struct Answer {
        uint256 questionId;
        address author;
        bytes32 contentHash;
        uint256 unlockFee;
        uint256 citedAnswerId; // 0 = no citation
        uint32 unlockCount;    // this answer's unlock count
    }

    // --- Reputation ---
    // Total unlocks received across all answers. On-chain reputation signal.
    mapping(address => uint256) public reputation;

    address public treasury;
    uint256 public nextQuestionId = 1;
    uint256 public nextAnswerId = 1;

    mapping(uint256 => Question) public questions;
    mapping(uint256 => Answer) public answers;
    mapping(uint256 => uint256[]) public questionAnswerIds;
    mapping(bytes32 => bool) public unlocks;
    mapping(bytes32 => bool) public votes;
    mapping(address => uint256) public earnings;

    event QuestionCreated(uint256 indexed id, address indexed author, bytes32 contentHash, uint256 stake);
    event AnswerCreated(uint256 indexed id, uint256 indexed questionId, address indexed author, uint256 unlockFee, uint256 citedAnswerId);
    event AnswerUnlocked(uint256 indexed answerId, address indexed reader, uint256 fee, uint256 authorShare, uint256 questionerShare, uint256 citationShare);
    event Upvoted(uint256 indexed questionId, address indexed voter);
    event QuestionSlashed(uint256 indexed id, uint256 burned, uint256 returned);
    event DeadlineExtended(uint256 indexed id, uint48 newDeadline);
    event Withdrawal(address indexed user, uint256 amount);
    event ReputationGained(address indexed user, uint256 totalReputation);

    error InsufficientStake();
    error QuestionNotFound();
    error AnswerNotFound();
    error AlreadyUnlocked();
    error SelfUnlock();
    error InsufficientPayment();
    error AlreadySlashed();
    error DeadlineNotPassed();
    error HasUnlocks();
    error AlreadyExtended();
    error NotAuthor();
    error AlreadyVoted();
    error NothingToWithdraw();
    error InvalidCitation();

    constructor(address _treasury) Ownable(msg.sender) {
        treasury = _treasury;
    }

    /// @notice Post a question by staking ETH. Questioner earns 10% of all unlock fees.
    function createQuestion(bytes32 contentHash) external payable whenNotPaused returns (uint256) {
        if (msg.value < MIN_STAKE) revert InsufficientStake();
        uint256 id = nextQuestionId++;
        questions[id] = Question({
            author: msg.sender,
            contentHash: contentHash,
            stake: msg.value,
            createdAt: uint48(block.timestamp),
            deadline: uint48(block.timestamp + SLASH_WINDOW),
            extended: false,
            slashed: false,
            unlockCount: 0,
            voteCount: 0
        });
        emit QuestionCreated(id, msg.sender, contentHash, msg.value);
        return id;
    }

    /// @notice Post an answer. Optionally cite another answer (cited author earns 5% on unlock).
    /// @param citedAnswerId The answer being cited/referenced. Pass 0 for no citation.
    function createAnswer(
        uint256 questionId,
        bytes32 contentHash,
        uint256 unlockFee,
        uint256 citedAnswerId
    ) external whenNotPaused returns (uint256) {
        Question storage q = questions[questionId];
        if (q.author == address(0)) revert QuestionNotFound();
        if (q.slashed) revert AlreadySlashed();
        // Validate citation if provided
        if (citedAnswerId != 0) {
            if (answers[citedAnswerId].author == address(0)) revert InvalidCitation();
        }
        uint256 id = nextAnswerId++;
        answers[id] = Answer({
            questionId: questionId,
            author: msg.sender,
            contentHash: contentHash,
            unlockFee: unlockFee,
            citedAnswerId: citedAnswerId,
            unlockCount: 0
        });
        questionAnswerIds[questionId].push(id);
        emit AnswerCreated(id, questionId, msg.sender, unlockFee, citedAnswerId);
        return id;
    }

    /// @notice Pay to unlock an answer.
    /// Split: 80% author, 10% questioner, 5% cited author (or author), 5% platform.
    function unlockAnswer(uint256 answerId) external payable nonReentrant whenNotPaused {
        Answer storage a = answers[answerId];
        if (a.author == address(0)) revert AnswerNotFound();
        if (a.author == msg.sender) revert SelfUnlock();
        if (msg.value < a.unlockFee) revert InsufficientPayment();

        bytes32 key = keccak256(abi.encodePacked(msg.sender, answerId));
        if (unlocks[key]) revert AlreadyUnlocked();
        unlocks[key] = true;

        // Calculate splits
        uint256 authorShare = (msg.value * AUTHOR_BPS) / 10_000;
        uint256 questionerShare = (msg.value * QUESTIONER_BPS) / 10_000;
        uint256 citationShare = (msg.value * CITATION_BPS) / 10_000;
        uint256 platformShare = msg.value - authorShare - questionerShare - citationShare;

        // Distribute
        earnings[a.author] += authorShare;
        earnings[questions[a.questionId].author] += questionerShare;
        earnings[treasury] += platformShare;

        // Citation: 5% to cited author, or back to answer author if no citation
        if (a.citedAnswerId != 0) {
            earnings[answers[a.citedAnswerId].author] += citationShare;
        } else {
            earnings[a.author] += citationShare;
        }

        // Update counts + reputation
        a.unlockCount++;
        questions[a.questionId].unlockCount++;
        reputation[a.author]++;
        emit ReputationGained(a.author, reputation[a.author]);

        emit AnswerUnlocked(answerId, msg.sender, msg.value, authorShare, questionerShare, citationShare);
    }

    /// @notice Free upvote on a question.
    function upvote(uint256 questionId) external whenNotPaused {
        if (questions[questionId].author == address(0)) revert QuestionNotFound();
        bytes32 key = keccak256(abi.encodePacked(msg.sender, questionId));
        if (votes[key]) revert AlreadyVoted();
        votes[key] = true;
        questions[questionId].voteCount++;
        emit Upvoted(questionId, msg.sender);
    }

    /// @notice Slash a question with no unlocks past deadline.
    function claimSlash(uint256 questionId) external {
        Question storage q = questions[questionId];
        if (q.author == address(0)) revert QuestionNotFound();
        if (q.slashed) revert AlreadySlashed();
        if (block.timestamp < q.deadline) revert DeadlineNotPassed();
        if (q.unlockCount > 0) revert HasUnlocks();
        q.slashed = true;
        uint256 returnAmount = q.stake / 2;
        earnings[q.author] += returnAmount;
        emit QuestionSlashed(questionId, q.stake - returnAmount, returnAmount);
    }

    /// @notice Extend deadline 30→90 days. Author only, costs +50% stake.
    function requestExtension(uint256 questionId) external payable {
        Question storage q = questions[questionId];
        if (q.author == address(0)) revert QuestionNotFound();
        if (q.author != msg.sender) revert NotAuthor();
        if (q.extended) revert AlreadyExtended();
        if (q.slashed) revert AlreadySlashed();
        if (msg.value < (q.stake * EXTEND_COST_BPS) / 10_000) revert InsufficientPayment();
        q.extended = true;
        q.stake += msg.value;
        q.deadline = uint48(q.createdAt + EXTEND_WINDOW);
        emit DeadlineExtended(questionId, q.deadline);
    }

    /// @notice Withdraw accumulated ETH earnings.
    function withdraw() external nonReentrant {
        uint256 amount = earnings[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        earnings[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
        emit Withdrawal(msg.sender, amount);
    }

    // --- Admin ---
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function setTreasury(address _treasury) external onlyOwner { treasury = _treasury; }

    // --- View ---
    function getQuestionAnswers(uint256 questionId) external view returns (uint256[] memory) {
        return questionAnswerIds[questionId];
    }
    function isUnlocked(address user, uint256 answerId) external view returns (bool) {
        return unlocks[keccak256(abi.encodePacked(user, answerId))];
    }
    function hasVoted(address user, uint256 questionId) external view returns (bool) {
        return votes[keccak256(abi.encodePacked(user, questionId))];
    }
}
