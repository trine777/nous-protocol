// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title NousCore — Question/Answer marketplace with ETH payments.
/// @notice Stake ETH to post questions. Pay to unlock answers (95/5 split).
///         Pure ETH model, no token. Token is v2.
contract NousCore is Pausable, ReentrancyGuard, Ownable {
    uint256 public constant MIN_STAKE = 0.01 ether;
    uint256 public constant PLATFORM_FEE_BPS = 500; // 5%
    uint256 public constant SLASH_WINDOW = 30 days;
    uint256 public constant EXTEND_WINDOW = 90 days;
    uint256 public constant EXTEND_COST_BPS = 5000; // 50% of original stake

    struct Question {
        address author;
        bytes32 contentHash;
        uint256 stake;
        uint48 createdAt;
        uint48 deadline;
        bool extended;
        bool slashed;
        uint32 unlockCount;
        uint32 voteCount;
    }

    struct Answer {
        uint256 questionId;
        address author;
        bytes32 contentHash;
        uint256 unlockFee;
    }

    address public treasury;
    uint256 public nextQuestionId = 1;
    uint256 public nextAnswerId = 1;

    mapping(uint256 => Question) public questions;
    mapping(uint256 => Answer) public answers;
    mapping(uint256 => uint256[]) public questionAnswerIds;
    mapping(bytes32 => bool) public unlocks;  // keccak256(user, answerId)
    mapping(bytes32 => bool) public votes;    // keccak256(voter, questionId)
    mapping(address => uint256) public earnings;

    event QuestionCreated(uint256 indexed id, address indexed author, bytes32 contentHash, uint256 stake);
    event AnswerCreated(uint256 indexed id, uint256 indexed questionId, address indexed author, uint256 unlockFee);
    event AnswerUnlocked(uint256 indexed answerId, address indexed reader, uint256 fee);
    event Upvoted(uint256 indexed questionId, address indexed voter);
    event QuestionSlashed(uint256 indexed id, uint256 burned, uint256 returned);
    event DeadlineExtended(uint256 indexed id, uint48 newDeadline);
    event Withdrawal(address indexed user, uint256 amount);

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

    constructor(address _treasury) Ownable(msg.sender) {
        treasury = _treasury;
    }

    /// @notice Post a question by staking ETH.
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

    /// @notice Post an answer to a question. Free to write.
    function createAnswer(uint256 questionId, bytes32 contentHash, uint256 unlockFee) external whenNotPaused returns (uint256) {
        Question storage q = questions[questionId];
        if (q.author == address(0)) revert QuestionNotFound();
        if (q.slashed) revert AlreadySlashed();
        uint256 id = nextAnswerId++;
        answers[id] = Answer({
            questionId: questionId,
            author: msg.sender,
            contentHash: contentHash,
            unlockFee: unlockFee
        });
        questionAnswerIds[questionId].push(id);
        emit AnswerCreated(id, questionId, msg.sender, unlockFee);
        return id;
    }

    /// @notice Pay to unlock an answer. 95% to author, 5% platform.
    function unlockAnswer(uint256 answerId) external payable nonReentrant whenNotPaused {
        Answer storage a = answers[answerId];
        if (a.author == address(0)) revert AnswerNotFound();
        if (a.author == msg.sender) revert SelfUnlock();
        if (msg.value < a.unlockFee) revert InsufficientPayment();
        bytes32 key = keccak256(abi.encodePacked(msg.sender, answerId));
        if (unlocks[key]) revert AlreadyUnlocked();
        unlocks[key] = true;

        uint256 platformFee = (msg.value * PLATFORM_FEE_BPS) / 10_000;
        earnings[a.author] += msg.value - platformFee;
        earnings[treasury] += platformFee;

        questions[a.questionId].unlockCount++;
        emit AnswerUnlocked(answerId, msg.sender, msg.value);
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

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function setTreasury(address _treasury) external onlyOwner { treasury = _treasury; }

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
