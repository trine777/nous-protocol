// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/NousCore.sol";

contract NousCoreTest is Test {
    NousCore core;
    address founder = address(0xF001);
    address treasury = address(0xF002);
    address alice = address(0xA001); // questioner
    address bob = address(0xA002);   // answerer
    address charlie = address(0xA003); // reader
    address dave = address(0xA004);  // cited answerer

    function setUp() public {
        vm.prank(founder);
        core = new NousCore(treasury);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(charlie, 10 ether);
        vm.deal(dave, 10 ether);
    }

    // --- createQuestion ---

    function test_createQuestion() public {
        vm.prank(alice);
        uint256 id = core.createQuestion{value: 0.01 ether}(keccak256("q1"));
        assertEq(id, 1);
        (address author,, uint256 stake,,,,,,) = core.questions(id);
        assertEq(author, alice);
        assertEq(stake, 0.01 ether);
    }

    function test_createQuestion_insufficientStake() public {
        vm.prank(alice);
        vm.expectRevert(NousCore.InsufficientStake.selector);
        core.createQuestion{value: 0.001 ether}(keccak256("cheap"));
    }

    // --- createAnswer + citation ---

    function test_createAnswer_noCitation() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.1 ether, 0);
        assertEq(aId, 1);
        (uint256 questionId, address author,,, uint256 cited,) = core.answers(aId);
        assertEq(questionId, qId);
        assertEq(author, bob);
        assertEq(cited, 0);
    }

    function test_createAnswer_withCitation() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(dave);
        uint256 a1 = core.createAnswer(qId, keccak256("a1"), 0.05 ether, 0);
        vm.prank(bob);
        uint256 a2 = core.createAnswer(qId, keccak256("a2"), 0.1 ether, a1);
        (,,,, uint256 cited,) = core.answers(a2);
        assertEq(cited, a1);
    }

    function test_createAnswer_invalidCitation() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        vm.expectRevert(NousCore.InvalidCitation.selector);
        core.createAnswer(qId, keccak256("a"), 0.1 ether, 999);
    }

    // --- unlockAnswer: fee split ---

    function test_unlock_splitNoCitation() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 1 ether, 0);

        vm.prank(charlie);
        core.unlockAnswer{value: 1 ether}(aId);

        // No citation: 80% + 5% citation back to author = 85%
        assertEq(core.earnings(bob), 0.85 ether);
        // Questioner gets 10%
        assertEq(core.earnings(alice), 0.1 ether);
        // Platform gets 5%
        assertEq(core.earnings(treasury), 0.05 ether);
    }

    function test_unlock_splitWithCitation() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(dave);
        uint256 a1 = core.createAnswer(qId, keccak256("a1"), 0.05 ether, 0);
        vm.prank(bob);
        uint256 a2 = core.createAnswer(qId, keccak256("a2"), 1 ether, a1);

        vm.prank(charlie);
        core.unlockAnswer{value: 1 ether}(a2);

        // Author (bob) gets 80%
        assertEq(core.earnings(bob), 0.8 ether);
        // Questioner (alice) gets 10%
        assertEq(core.earnings(alice), 0.1 ether);
        // Cited author (dave) gets 5%
        assertEq(core.earnings(dave), 0.05 ether);
        // Platform gets 5%
        assertEq(core.earnings(treasury), 0.05 ether);
    }

    function test_unlock_selfUnlock() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.1 ether, 0);
        vm.prank(bob);
        vm.expectRevert(NousCore.SelfUnlock.selector);
        core.unlockAnswer{value: 0.1 ether}(aId);
    }

    function test_unlock_alreadyUnlocked() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.1 ether, 0);
        vm.prank(charlie);
        core.unlockAnswer{value: 0.1 ether}(aId);
        vm.prank(charlie);
        vm.expectRevert(NousCore.AlreadyUnlocked.selector);
        core.unlockAnswer{value: 0.1 ether}(aId);
    }

    // --- reputation ---

    function test_reputation_increments() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.01 ether, 0);

        assertEq(core.reputation(bob), 0);

        for (uint160 i = 1; i <= 5; i++) {
            address reader = address(i + 5000);
            vm.deal(reader, 1 ether);
            vm.prank(reader);
            core.unlockAnswer{value: 0.01 ether}(aId);
        }

        assertEq(core.reputation(bob), 5);
    }

    // --- questioner earns from multiple answers ---

    function test_questionerEarnsFromAllAnswers() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));

        // Two different answerers
        vm.prank(bob);
        uint256 a1 = core.createAnswer(qId, keccak256("a1"), 0.1 ether, 0);
        vm.prank(dave);
        uint256 a2 = core.createAnswer(qId, keccak256("a2"), 0.2 ether, 0);

        // Unlock both
        vm.prank(charlie);
        core.unlockAnswer{value: 0.1 ether}(a1);
        vm.prank(charlie);
        core.unlockAnswer{value: 0.2 ether}(a2);

        // Alice (questioner) earns 10% of both: 0.01 + 0.02 = 0.03 ETH
        assertEq(core.earnings(alice), 0.03 ether);
    }

    // --- citation chain: A cites B, unlocking A pays B ---

    function test_citationChain() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));

        vm.prank(dave);
        uint256 a1 = core.createAnswer(qId, keccak256("foundation"), 0.05 ether, 0);
        vm.prank(bob);
        uint256 a2 = core.createAnswer(qId, keccak256("builds on a1"), 0.1 ether, a1);

        // Unlock a2 (which cites a1)
        vm.prank(charlie);
        core.unlockAnswer{value: 0.1 ether}(a2);

        // Dave (cited) earns 5% = 0.005 ETH from bob's answer being unlocked
        assertEq(core.earnings(dave), 0.005 ether);

        // Now unlock a1 directly too
        vm.prank(charlie);
        core.unlockAnswer{value: 0.05 ether}(a1);

        // Dave now also earns as author of a1: 85% of 0.05 = 0.0425 (80% + 5% no-citation)
        // Total dave: 0.005 + 0.0425 = 0.0475
        assertEq(core.earnings(dave), 0.0475 ether);
    }

    // --- withdraw ---

    function test_withdraw() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 1 ether, 0);
        vm.prank(charlie);
        core.unlockAnswer{value: 1 ether}(aId);

        uint256 before = bob.balance;
        vm.prank(bob);
        core.withdraw();
        assertEq(bob.balance - before, 0.85 ether);
    }

    function test_withdraw_nothing() public {
        vm.prank(alice);
        vm.expectRevert(NousCore.NothingToWithdraw.selector);
        core.withdraw();
    }

    // --- slash ---

    function test_claimSlash() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 1 ether}(keccak256("q"));
        vm.warp(block.timestamp + 31 days);
        core.claimSlash(qId);
        assertEq(core.earnings(alice), 0.5 ether);
        (,,,,,,bool slashed,,) = core.questions(qId);
        assertTrue(slashed);
    }

    function test_claimSlash_hasUnlocks() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.01 ether, 0);
        vm.prank(charlie);
        core.unlockAnswer{value: 0.01 ether}(aId);
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert(NousCore.HasUnlocks.selector);
        core.claimSlash(qId);
    }

    function test_claimSlash_tooEarly() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.expectRevert(NousCore.DeadlineNotPassed.selector);
        core.claimSlash(qId);
    }

    // --- extension ---

    function test_requestExtension() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(alice);
        core.requestExtension{value: 0.005 ether}(qId);
        (,,,, uint48 deadline, bool extended,,,) = core.questions(qId);
        assertTrue(extended);
        assertGt(deadline, uint48(block.timestamp + 60 days));
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
        (,,,,,,,,uint32 voteCount) = core.questions(qId);
        assertEq(voteCount, 1);
    }

    function test_upvote_double() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        core.upvote(qId);
        vm.prank(bob);
        vm.expectRevert(NousCore.AlreadyVoted.selector);
        core.upvote(qId);
    }

    // --- pause ---

    function test_pause() public {
        vm.prank(founder);
        core.pause();
        vm.prank(alice);
        vm.expectRevert();
        core.createQuestion{value: 0.01 ether}(keccak256("q"));
    }
}
