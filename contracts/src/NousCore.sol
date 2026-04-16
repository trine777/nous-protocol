// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title NousCore — Thought marketplace: free discussion + paid deep content.
/// @notice Two modes:
///   - Free questions: open discussion, all answers free to read
///   - Paid questions: stake ETH, answers can be paid-to-unlock, stake refunded on first unlock
/// Five incentive mechanisms:
///   1. Questioner royalty (15%) 2. Citation (5%) 3. Fork (5%) 4. Reputation 5. Co-build pool (10%)
contract NousCore is Pausable, ReentrancyGuard, Ownable {
    uint256 public constant MIN_STAKE = 0.01 ether;
    uint256 public constant SLASH_WINDOW = 30 days;
    uint256 public constant EXTEND_WINDOW = 90 days;
    uint256 public constant EXTEND_COST_BPS = 5000;

    uint256 public constant AUTHOR_BPS = 6500;
    uint256 public constant QUESTIONER_BPS = 1500;
    uint256 public constant CITATION_BPS = 500;
    uint256 public constant FORK_BPS = 500;
    uint256 public constant COBUILD_BPS = 1000;

    struct Question {
        address author;
        bytes32 contentHash;
        uint256 stake;          // 0 = free, >0 = paid
        uint48 createdAt;
        uint48 deadline;
        bool extended;
        bool slashed;
        bool stakeRefunded;     // FIX: track stake refund on first unlock
        uint32 unlockCount;
        uint32 voteCount;
        uint256 parentQuestionId;
    }

    struct Answer {
        uint256 questionId;
        address author;
        bytes32 contentHash;
        uint256 unlockFee;
        uint256 citedAnswerId;
        uint32 unlockCount;
    }

    enum ProposalStatus { Active, Approved, Completed, Rejected }

    struct Proposal {
        address proposer;
        bytes32 contentHash;
        uint256 budget;
        uint256 votePower;
        uint256 voterCount;
        ProposalStatus status;
        uint48 createdAt;
    }

    mapping(address => uint256) public reputation;
    mapping(address => uint256) public earnings;

    address public treasury;
    uint256 public coBuildPool;
    uint256 public nextQuestionId = 1;
    uint256 public nextAnswerId = 1;
    uint256 public nextProposalId = 1;
    uint256 public proposalThreshold = 50;

    mapping(uint256 => Question) public questions;
    mapping(uint256 => Answer) public answers;
    mapping(uint256 => uint256[]) public questionAnswerIds;
    mapping(uint256 => uint256[]) public questionForks;
    mapping(bytes32 => bool) public unlocks;
    mapping(bytes32 => bool) public votes;
    mapping(uint256 => Proposal) public proposals;
    mapping(bytes32 => bool) public proposalVotes;

    event QuestionCreated(uint256 indexed id, address indexed author, bool paid, uint256 stake, uint256 parentQuestionId);
    event AnswerCreated(uint256 indexed id, uint256 indexed questionId, address indexed author, uint256 unlockFee, uint256 citedAnswerId);
    event AnswerUnlocked(uint256 indexed answerId, address indexed reader, uint256 fee);
    event StakeRefunded(uint256 indexed questionId, address indexed author, uint256 amount);
    event Upvoted(uint256 indexed questionId, address indexed voter);
    event QuestionSlashed(uint256 indexed id, uint256 burned, uint256 returned);
    event DeadlineExtended(uint256 indexed id, uint48 newDeadline);
    event Withdrawal(address indexed user, uint256 amount);
    event ReputationGained(address indexed user, uint256 total);
    event CoBuildDeposit(uint256 amount, uint256 poolTotal);
    event ProposalCreated(uint256 indexed id, address indexed proposer, uint256 budget);
    event ProposalVoted(uint256 indexed id, address indexed voter, uint256 votePower);
    event ProposalApproved(uint256 indexed id);
    event BountyClaimed(uint256 indexed proposalId, address indexed contributor, uint256 amount);

    error InsufficientStake();
    error QuestionNotFound();
    error AnswerNotFound();
    error AlreadyUnlocked();
    error SelfUnlock();
    error InsufficientPayment();
    error AlreadySlashed();
    error QuestionSlashedErr();
    error DeadlineNotPassed();
    error HasUnlocks();
    error AlreadyExtended();
    error NotAuthor();
    error AlreadyVoted();
    error NothingToWithdraw();
    error InvalidCitation();
    error InvalidParent();
    error ProposalNotFound();
    error ProposalNotActive();
    error ProposalNotApproved();
    error InsufficientPool();
    error NoReputation();
    error FreeQuestionPaidAnswer();
    error AnswerIsFree();
    error NotPaidQuestion();

    constructor(address _treasury) Ownable(msg.sender) {
        treasury = _treasury;
    }

    // ============================================================
    // Questions
    // ============================================================

    function createFreeQuestion(bytes32 contentHash) external whenNotPaused returns (uint256) {
        return _createQuestion(contentHash, 0, 0);
    }

    function createPaidQuestion(bytes32 contentHash) external payable whenNotPaused returns (uint256) {
        if (msg.value < MIN_STAKE) revert InsufficientStake();
        return _createQuestion(contentHash, msg.value, 0);
    }

    /// @notice Fork a question. Paid parent → fork must stake ≥ MIN_STAKE. Free parent → fork is free.
    function forkQuestion(uint256 parentQuestionId, bytes32 contentHash) external payable whenNotPaused returns (uint256) {
        Question storage parent = questions[parentQuestionId];
        if (parent.author == address(0)) revert InvalidParent();
        // FIX: paid parent requires MIN_STAKE, free parent requires 0
        if (parent.stake > 0 && msg.value < MIN_STAKE) revert InsufficientStake();
        if (parent.stake == 0 && msg.value > 0) revert InsufficientStake(); // free fork must be free
        uint256 id = _createQuestion(contentHash, msg.value, parentQuestionId);
        questionForks[parentQuestionId].push(id);
        return id;
    }

    function _createQuestion(bytes32 contentHash, uint256 stake, uint256 parentId) internal returns (uint256) {
        uint256 id = nextQuestionId++;
        questions[id] = Question({
            author: msg.sender,
            contentHash: contentHash,
            stake: stake,
            createdAt: uint48(block.timestamp),
            deadline: stake > 0 ? uint48(block.timestamp + SLASH_WINDOW) : 0,
            extended: false,
            slashed: false,
            stakeRefunded: false,
            unlockCount: 0,
            voteCount: 0,
            parentQuestionId: parentId
        });
        emit QuestionCreated(id, msg.sender, stake > 0, stake, parentId);
        return id;
    }

    // ============================================================
    // Answers
    // ============================================================

    function createAnswer(
        uint256 questionId, bytes32 contentHash, uint256 unlockFee, uint256 citedAnswerId
    ) external whenNotPaused returns (uint256) {
        Question storage q = questions[questionId];
        if (q.author == address(0)) revert QuestionNotFound();
        if (q.slashed) revert QuestionSlashedErr(); // FIX: use distinct error
        if (q.stake == 0 && unlockFee > 0) revert FreeQuestionPaidAnswer();
        if (citedAnswerId != 0 && answers[citedAnswerId].author == address(0)) revert InvalidCitation();

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

    // ============================================================
    // Unlock
    // ============================================================

    function unlockAnswer(uint256 answerId) external payable nonReentrant whenNotPaused {
        Answer storage a = answers[answerId];
        if (a.author == address(0)) revert AnswerNotFound();
        if (a.unlockFee == 0) revert AnswerIsFree();
        if (a.author == msg.sender) revert SelfUnlock();
        if (msg.value < a.unlockFee) revert InsufficientPayment();

        Question storage q = questions[a.questionId];
        if (q.slashed) revert QuestionSlashedErr(); // FIX: can't unlock on slashed question

        bytes32 key = keccak256(abi.encodePacked(msg.sender, answerId));
        if (unlocks[key]) revert AlreadyUnlocked();
        unlocks[key] = true;

        // Fee distribution
        uint256 authorShare = (msg.value * AUTHOR_BPS) / 10_000;
        uint256 questionerShare = (msg.value * QUESTIONER_BPS) / 10_000;
        uint256 citationShare = (msg.value * CITATION_BPS) / 10_000;
        uint256 forkShare = (msg.value * FORK_BPS) / 10_000;
        uint256 cobuildShare = msg.value - authorShare - questionerShare - citationShare - forkShare;

        earnings[a.author] += authorShare;
        earnings[q.author] += questionerShare;

        if (a.citedAnswerId != 0) {
            earnings[answers[a.citedAnswerId].author] += citationShare;
        } else {
            earnings[a.author] += citationShare;
        }

        if (q.parentQuestionId != 0) {
            earnings[questions[q.parentQuestionId].author] += forkShare;
        } else {
            earnings[a.author] += forkShare;
        }

        coBuildPool += cobuildShare;
        emit CoBuildDeposit(cobuildShare, coBuildPool);

        // FIX: refund stake to questioner on first unlock
        if (!q.stakeRefunded && q.stake > 0) {
            q.stakeRefunded = true;
            earnings[q.author] += q.stake;
            emit StakeRefunded(a.questionId, q.author, q.stake);
        }

        a.unlockCount++;
        q.unlockCount++;
        reputation[a.author]++;
        emit ReputationGained(a.author, reputation[a.author]);
        emit AnswerUnlocked(answerId, msg.sender, msg.value);
    }

    // ============================================================
    // Upvote
    // ============================================================

    function upvote(uint256 questionId) external whenNotPaused {
        if (questions[questionId].author == address(0)) revert QuestionNotFound();
        bytes32 key = keccak256(abi.encodePacked(msg.sender, questionId));
        if (votes[key]) revert AlreadyVoted();
        votes[key] = true;
        questions[questionId].voteCount++;
        emit Upvoted(questionId, msg.sender);
    }

    // ============================================================
    // Slash + Extension (paid questions only)
    // ============================================================

    function claimSlash(uint256 questionId) external {
        Question storage q = questions[questionId];
        if (q.author == address(0)) revert QuestionNotFound();
        if (q.stake == 0) revert NotPaidQuestion();
        if (q.slashed) revert AlreadySlashed();
        if (block.timestamp < q.deadline) revert DeadlineNotPassed();
        if (q.unlockCount > 0) revert HasUnlocks();
        q.slashed = true;
        uint256 returnAmount = q.stake / 2;
        earnings[q.author] += returnAmount;
        emit QuestionSlashed(questionId, q.stake - returnAmount, returnAmount);
    }

    function requestExtension(uint256 questionId) external payable {
        Question storage q = questions[questionId];
        if (q.author == address(0)) revert QuestionNotFound();
        if (q.stake == 0) revert NotPaidQuestion();
        if (q.author != msg.sender) revert NotAuthor();
        if (q.extended) revert AlreadyExtended();
        if (q.slashed) revert AlreadySlashed();
        if (msg.value < (q.stake * EXTEND_COST_BPS) / 10_000) revert InsufficientPayment();
        q.extended = true;
        q.stake += msg.value;
        q.deadline = uint48(q.createdAt + EXTEND_WINDOW);
        emit DeadlineExtended(questionId, q.deadline);
    }

    // ============================================================
    // Co-build: proposals funded by 10% platform revenue
    // FIX: claimBounty restricted to onlyOwner (multisig) to prevent theft
    // ============================================================

    function createProposal(bytes32 contentHash, uint256 budget) external whenNotPaused returns (uint256) {
        if (budget > coBuildPool) revert InsufficientPool();
        uint256 id = nextProposalId++;
        proposals[id] = Proposal({
            proposer: msg.sender,
            contentHash: contentHash,
            budget: budget,
            votePower: 0,
            voterCount: 0,
            status: ProposalStatus.Active,
            createdAt: uint48(block.timestamp)
        });
        emit ProposalCreated(id, msg.sender, budget);
        return id;
    }

    function voteProposal(uint256 proposalId) external whenNotPaused {
        Proposal storage p = proposals[proposalId];
        if (p.proposer == address(0)) revert ProposalNotFound();
        if (p.status != ProposalStatus.Active) revert ProposalNotActive();
        uint256 rep = reputation[msg.sender];
        if (rep == 0) revert NoReputation();

        bytes32 key = keccak256(abi.encodePacked(msg.sender, proposalId));
        if (proposalVotes[key]) revert AlreadyVoted();
        proposalVotes[key] = true;

        p.votePower += rep;
        p.voterCount++;
        emit ProposalVoted(proposalId, msg.sender, rep);

        if (p.votePower >= proposalThreshold) {
            p.status = ProposalStatus.Approved;
            emit ProposalApproved(proposalId);
        }
    }

    /// @notice Release bounty for approved proposal. Owner (multisig) only.
    function claimBounty(uint256 proposalId, address contributor) external onlyOwner {
        Proposal storage p = proposals[proposalId];
        if (p.proposer == address(0)) revert ProposalNotFound();
        if (p.status != ProposalStatus.Approved) revert ProposalNotApproved();
        if (p.budget > coBuildPool) revert InsufficientPool();
        p.status = ProposalStatus.Completed;
        coBuildPool -= p.budget;
        earnings[contributor] += p.budget;
        emit BountyClaimed(proposalId, contributor, p.budget);
    }

    function setProposalThreshold(uint256 _threshold) external onlyOwner {
        proposalThreshold = _threshold;
    }

    // ============================================================
    // Withdraw + Admin
    // ============================================================

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

    // ============================================================
    // View
    // ============================================================

    function isPaidQuestion(uint256 questionId) external view returns (bool) {
        return questions[questionId].stake > 0;
    }
    function getQuestionAnswers(uint256 questionId) external view returns (uint256[] memory) {
        return questionAnswerIds[questionId];
    }
    function getQuestionForks(uint256 questionId) external view returns (uint256[] memory) {
        return questionForks[questionId];
    }
    function isUnlocked(address user, uint256 answerId) external view returns (bool) {
        return unlocks[keccak256(abi.encodePacked(user, answerId))];
    }
    function hasVoted(address user, uint256 questionId) external view returns (bool) {
        return votes[keccak256(abi.encodePacked(user, questionId))];
    }
    function hasVotedProposal(address user, uint256 proposalId) external view returns (bool) {
        return proposalVotes[keccak256(abi.encodePacked(user, proposalId))];
    }
}
