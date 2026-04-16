// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/NousToken.sol";
import "../src/NousCore.sol";
import "../src/RewardDistributor.sol";

contract NousCoreTest is Test {
    NousToken token;
    RewardDistributor distributor;
    NousCore core;

    address founder = address(0xF001);
    address treasury = address(0xF002);
    address alice = address(0xA001);
    address bob = address(0xA002);
    address charlie = address(0xA003);

    function setUp() public {
        vm.startPrank(founder);

        token = new NousToken();
        distributor = new RewardDistributor(address(token));
        core = new NousCore(address(token), address(distributor), treasury);

        // Fund distributor with 40M reward pool
        token.transfer(address(distributor), 40_000_000e18);
        distributor.setCore(address(core));

        vm.stopPrank();

        // Fund test accounts
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(charlie, 10 ether);
    }

    // --- createQuestion ---

    function test_createQuestion() public {
        vm.prank(alice);
        uint256 id = core.createQuestion{value: 0.01 ether}(keccak256("test question"));
        assertEq(id, 1);

        (address author,,uint256 stake,,,,,,,) = core.questions(id);
        assertEq(author, alice);
        assertEq(stake, 0.01 ether);
    }

    function test_createQuestion_insufficientStake() public {
        vm.prank(alice);
        vm.expectRevert(NousCore.InsufficientStake.selector);
        core.createQuestion{value: 0.001 ether}(keccak256("cheap"));
    }

    // --- createAnswer ---

    function test_createAnswer() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q1"));

        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("answer1"), 0.005 ether);
        assertEq(aId, 1);

        (uint256 questionId, address author,, uint256 fee,) = core.answers(aId);
        assertEq(questionId, qId);
        assertEq(author, bob);
        assertEq(fee, 0.005 ether);
    }

    function test_createAnswer_questionNotFound() public {
        vm.prank(bob);
        vm.expectRevert(NousCore.QuestionNotFound.selector);
        core.createAnswer(999, keccak256("orphan"), 0.005 ether);
    }

    // --- unlockAnswer ---

    function test_unlockAnswer() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));

        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.005 ether);

        vm.prank(charlie);
        core.unlockAnswer{value: 0.005 ether}(aId);

        assertTrue(core.isUnlocked(charlie, aId));

        // Bob (author) should have 90% = 0.0045 ether in earnings
        assertEq(core.earnings(bob), 0.0045 ether);
        // Treasury gets 10% = 0.0005 ether
        assertEq(core.earnings(treasury), 0.0005 ether);
    }

    function test_unlockAnswer_selfUnlock() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));

        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.005 ether);

        vm.prank(bob);
        vm.expectRevert(NousCore.SelfUnlock.selector);
        core.unlockAnswer{value: 0.005 ether}(aId);
    }

    function test_unlockAnswer_alreadyUnlocked() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));

        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.005 ether);

        vm.prank(charlie);
        core.unlockAnswer{value: 0.005 ether}(aId);

        vm.prank(charlie);
        vm.expectRevert(NousCore.AlreadyUnlocked.selector);
        core.unlockAnswer{value: 0.005 ether}(aId);
    }

    function test_unlockAnswer_rewards() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));

        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.005 ether);

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(charlie);
        core.unlockAnswer{value: 0.005 ether}(aId);

        // Alice (question author) gets 100 $NOUS reward
        assertEq(token.balanceOf(alice) - aliceBefore, 100e18);
        // Bob (answer author) gets 50 $NOUS reward
        assertEq(token.balanceOf(bob) - bobBefore, 50e18);
    }

    // --- withdraw ---

    function test_withdraw() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));

        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.1 ether);

        vm.prank(charlie);
        core.unlockAnswer{value: 0.1 ether}(aId);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        core.withdraw();
        assertEq(bob.balance - bobBefore, 0.09 ether); // 90%
    }

    function test_withdraw_nothingToWithdraw() public {
        vm.prank(alice);
        vm.expectRevert(NousCore.NothingToWithdraw.selector);
        core.withdraw();
    }

    // --- claimSlash ---

    function test_claimSlash() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 1 ether}(keccak256("q"));

        // Fast forward past deadline
        vm.warp(block.timestamp + 31 days);

        core.claimSlash(qId);

        // Alice gets 50% back
        assertEq(core.earnings(alice), 0.5 ether);

        // Question is slashed
        (,,,,,,bool slashed,,,) = core.questions(qId);
        assertTrue(slashed);
    }

    function test_claimSlash_hasUnlocks() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));

        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.005 ether);

        vm.prank(charlie);
        core.unlockAnswer{value: 0.005 ether}(aId);

        vm.warp(block.timestamp + 31 days);

        vm.expectRevert(NousCore.HasUnlocks.selector);
        core.claimSlash(qId);
    }

    function test_claimSlash_deadlineNotPassed() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));

        vm.expectRevert(NousCore.DeadlineNotPassed.selector);
        core.claimSlash(qId);
    }

    // --- requestExtension ---

    function test_requestExtension() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));

        vm.prank(alice);
        core.requestExtension{value: 0.005 ether}(qId); // 50% of 0.01

        (,,,,uint48 deadline, bool extended,,,,) = core.questions(qId);
        assertTrue(extended);
        // deadline should be createdAt + 90 days
    }

    function test_requestExtension_notAuthor() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));

        vm.prank(bob);
        vm.expectRevert(NousCore.NotAuthor.selector);
        core.requestExtension{value: 0.005 ether}(qId);
    }

    // --- upvote ---

    function test_upvote() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));

        vm.prank(bob);
        core.upvote(qId);

        assertTrue(core.hasVoted(bob, qId));
        (,,,,,,,,,uint32 voteCount) = core.questions(qId);
        assertEq(voteCount, 1);
    }

    function test_upvote_alreadyVoted() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));

        vm.prank(bob);
        core.upvote(qId);

        vm.prank(bob);
        vm.expectRevert(NousCore.AlreadyVoted.selector);
        core.upvote(qId);
    }

    // --- claimVoterReward ---

    function test_claimVoterReward() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));

        vm.prank(bob);
        core.upvote(qId);

        // Create answer and simulate 10 unlocks
        vm.prank(alice);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.001 ether);

        for (uint160 i = 1; i <= 10; i++) {
            address unlcker = address(i + 1000);
            vm.deal(unlcker, 1 ether);
            vm.prank(unlcker);
            core.unlockAnswer{value: 0.001 ether}(aId);
        }

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        core.claimVoterReward(qId);
        assertEq(token.balanceOf(bob) - bobBefore, 10e18); // 10 $NOUS
    }

    // --- Pausable ---

    function test_pause() public {
        vm.prank(founder);
        core.pause();

        vm.prank(alice);
        vm.expectRevert();
        core.createQuestion{value: 0.01 ether}(keccak256("q"));
    }

    // --- RewardDistributor daily limit ---

    function test_rewardDistributor_dailyLimit() public {
        // 10,000 $NOUS per day. Each unlock gives 150 (100 q + 50 a).
        // 66 unlocks = 9900, 67th = 10050 > 10000.
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));

        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.001 ether);

        // First 66 unlocks should succeed
        for (uint160 i = 1; i <= 66; i++) {
            address u = address(i + 2000);
            vm.deal(u, 1 ether);
            vm.prank(u);
            core.unlockAnswer{value: 0.001 ether}(aId);
        }

        // 67th unlock still succeeds (ETH part works) but reward silently fails (try/catch)
        address u67 = address(2067);
        vm.deal(u67, 1 ether);
        vm.prank(u67);
        core.unlockAnswer{value: 0.001 ether}(aId); // no revert, reward just skipped
    }
}
