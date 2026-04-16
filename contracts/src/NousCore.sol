// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRewardDistributor {
    function distribute(address to, uint256 amount) external;
}

/// @title NousCore — Question/Answer marketplace with ETH payments and $NOUS rewards.
/// @notice Stake ETH to post questions. Pay to unlock answers (90/10 split).
///         Contributors earn $NOUS tokens via RewardDistributor.
contract NousCore is Pausable, ReentrancyGuard, Ownable {
    // --- Constants ---
    uint256 public constant MIN_STAKE = 0.01 ether;
    uint256 public constant PLATFORM_FEE_BPS = 1000; // 10%
    uint256 public constant SLASH_WINDOW = 30 days;
    uint256 public constant EXTEND_WINDOW = 90 days;
    uint256 public constant EXTEND_COST_BPS = 5000; // 50% of original stake

    uint256 public constant QUESTION_REWARD = 100e18;  // 100 $NOUS
    uint256 public constant ANSWER_REWARD = 50e18;     // 50 $NOUS per unlock
    uint256 public constant VOTER_REWARD = 10e18;      // 10 $NOUS
    uint256 public constant MAX_QUESTION_REWARDS = 10;
    uint256 public constant MAX_ANSWER_REWARDS = 100;
    uint256 public constant TOP_UNLOCK_THRESHOLD = 10;  // top-10 by unlocks for voter reward

    // --- Structs ---
    struct Question {
        address author;
        bytes32 contentHash;
        uint256 stake;
        uint48 createdAt;
        uint48 deadline;
        bool extended;
        bool slashed;
        uint32 unlockCount;
        uint32 rewardsClaimed;
        uint32 voteCount;
    }

    struct Answer {
        uint256 questionId;
        address author;
        bytes32 contentHash;
        uint256 unlockFee;
        uint32 rewardsClaimed;
    }

    // --- State ---
    IERC20 public immutable nousToken;
    IRewardDistributor public immutable rewardDistributor;
    address public treasury;

    uint256 public nextQuestionId = 1;
    uint256 public nextAnswerId = 1;

    mapping(uint256 => Question) public questions;
    mapping(uint256 => Answer) public answers;
    mapping(uint256 => uint256[]) public questionAnswerIds;

    // keccak256(user, answerId) => unlocked
    mapping(bytes32 => bool) public unlocks;
    // keccak256(voter, questionId) => voted
    mapping(bytes32 => bool) public votes;
    // keccak256(voter, questionId) => voter reward claimed
    mapping(bytes32 => bool) public voterRewardClaimed;
    // user => accumulated ETH earnings (withdraw pattern)
    mapping(address => uint256) public earnings;

    // --- Events ---
    event QuestionCreated(uint256 indexed id, address indexed author, bytes32 contentHash, uint256 stake);
    event AnswerCreated(uint256 indexed id, uint256 indexed questionId, address indexed author, uint256 unlockFee);
    event AnswerUnlocked(uint256 indexed answerId, address indexed reader, uint256 fee);
    event Upvoted(uint256 indexed questionId, address indexed voter);
    event QuestionSlashed(uint256 indexed id, uint256 burned, uint256 returned);
    event DeadlineExtended(uint256 indexed id, uint48 newDeadline);
    event Withdrawal(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount, string rewardType);

    // --- Errors ---
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
    error RewardCapReached();
    error NotEligible();
    error NothingToWithdraw();

    constructor(address _nousToken, address _rewardDistributor, address _treasury) Ownable(msg.sender) {
        nousToken = IERC20(_nousToken);
        rewardDistributor = IRewardDistributor(_rewardDistributor);
        treasury = _treasury;
    }

    // --- Core Functions ---

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
            rewardsClaimed: 0,
            voteCount: 0
        });

        emit QuestionCreated(id, msg.sender, contentHash, msg.value);
        return id;
    }

    /// @notice Post an answer to a question.
    function createAnswer(uint256 questionId, bytes32 contentHash, uint256 unlockFee) external whenNotPaused returns (uint256) {
        Question storage q = questions[questionId];
        if (q.author == address(0)) revert QuestionNotFound();
        if (q.slashed) revert AlreadySlashed();

        uint256 id = nextAnswerId++;
        answers[id] = Answer({
            questionId: questionId,
            author: msg.sender,
            contentHash: contentHash,
            unlockFee: unlockFee,
            rewardsClaimed: 0
        });
        questionAnswerIds[questionId].push(id);

        emit AnswerCreated(id, questionId, msg.sender, unlockFee);
        return id;
    }

    /// @notice Pay to unlock an answer. 90% to author, 10% platform (50% buyback-burn, 50% treasury).
    function unlockAnswer(uint256 answerId) external payable nonReentrant whenNotPaused {
        Answer storage a = answers[answerId];
        if (a.author == address(0)) revert AnswerNotFound();
        if (a.author == msg.sender) revert SelfUnlock();
        if (msg.value < a.unlockFee) revert InsufficientPayment();

        bytes32 key = keccak256(abi.encodePacked(msg.sender, answerId));
        if (unlocks[key]) revert AlreadyUnlocked();
        unlocks[key] = true;

        // Split: 90% author, 5% buyback-burn, 5% treasury
        uint256 platformFee = (msg.value * PLATFORM_FEE_BPS) / 10_000;
        uint256 authorShare = msg.value - platformFee;
        uint256 burnShare = platformFee / 2;
        uint256 treasuryShare = platformFee - burnShare;

        earnings[a.author] += authorShare;
        earnings[treasury] += treasuryShare;

        // Buyback-burn: send ETH to treasury, treasury handles buyback off-chain (v1 simplification)
        // In v2, integrate with Uniswap router for on-chain buyback.
        earnings[treasury] += burnShare; // treasury does manual buyback-burn for now

        // Update question unlock count
        Question storage q = questions[a.questionId];
        q.unlockCount++;

        // Distribute $NOUS rewards (if caps not reached)
        _tryDistributeQuestionReward(q);
        _tryDistributeAnswerReward(a);

        emit AnswerUnlocked(answerId, msg.sender, msg.value);
    }

    /// @notice Free upvote on a question.
    function upvote(uint256 questionId) external whenNotPaused {
        Question storage q = questions[questionId];
        if (q.author == address(0)) revert QuestionNotFound();

        bytes32 key = keccak256(abi.encodePacked(msg.sender, questionId));
        if (votes[key]) revert AlreadyVoted();
        votes[key] = true;
        q.voteCount++;

        emit Upvoted(questionId, msg.sender);
    }

    /// @notice Claim voter reward if the question reached top unlock threshold.
    function claimVoterReward(uint256 questionId) external {
        Question storage q = questions[questionId];
        if (q.author == address(0)) revert QuestionNotFound();
        if (q.unlockCount < TOP_UNLOCK_THRESHOLD) revert NotEligible();

        bytes32 voteKey = keccak256(abi.encodePacked(msg.sender, questionId));
        if (!votes[voteKey]) revert NotEligible();

        bytes32 claimKey = keccak256(abi.encodePacked(msg.sender, questionId, "voter"));
        if (voterRewardClaimed[claimKey]) revert RewardCapReached();
        voterRewardClaimed[claimKey] = true;

        rewardDistributor.distribute(msg.sender, VOTER_REWARD);
        emit RewardClaimed(msg.sender, VOTER_REWARD, "voter");
    }

    /// @notice Slash a question with no unlocks past deadline.
    function claimSlash(uint256 questionId) external {
        Question storage q = questions[questionId];
        if (q.author == address(0)) revert QuestionNotFound();
        if (q.slashed) revert AlreadySlashed();
        if (block.timestamp < q.deadline) revert DeadlineNotPassed();
        if (q.unlockCount > 0) revert HasUnlocks();

        q.slashed = true;
        uint256 slashAmount = q.stake / 2;
        uint256 returnAmount = q.stake - slashAmount;

        // Return 50% to author, burn 50% (send to address(0) equivalent — just don't send it)
        earnings[q.author] += returnAmount;
        // slashAmount stays locked in contract forever (effective burn)

        emit QuestionSlashed(questionId, slashAmount, returnAmount);
    }

    /// @notice Extend question deadline from 30 to 90 days. Author only, costs +50% stake.
    function requestExtension(uint256 questionId) external payable {
        Question storage q = questions[questionId];
        if (q.author == address(0)) revert QuestionNotFound();
        if (q.author != msg.sender) revert NotAuthor();
        if (q.extended) revert AlreadyExtended();
        if (q.slashed) revert AlreadySlashed();

        uint256 cost = (q.stake * EXTEND_COST_BPS) / 10_000;
        if (msg.value < cost) revert InsufficientPayment();

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

    // --- Internal ---
    function _tryDistributeQuestionReward(Question storage q) internal {
        if (q.rewardsClaimed < MAX_QUESTION_REWARDS) {
            q.rewardsClaimed++;
            try rewardDistributor.distribute(q.author, QUESTION_REWARD) {
                emit RewardClaimed(q.author, QUESTION_REWARD, "question");
            } catch {}
        }
    }

    function _tryDistributeAnswerReward(Answer storage a) internal {
        if (a.rewardsClaimed < MAX_ANSWER_REWARDS) {
            a.rewardsClaimed++;
            try rewardDistributor.distribute(a.author, ANSWER_REWARD) {
                emit RewardClaimed(a.author, ANSWER_REWARD, "answer");
            } catch {}
        }
    }
}
