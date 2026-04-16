// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/NousCore.sol";

contract NousCoreTest is Test {
    NousCore core;
    address founder = address(0xF001);
    address treasury = address(0xF002);
    address alice = address(0xA001);   // questioner
    address bob = address(0xA002);     // answerer
    address charlie = address(0xA003); // reader
    address dave = address(0xA004);    // cited answerer
    address eve = address(0xA005);     // attacker

    function setUp() public {
        vm.prank(founder);
        core = new NousCore(treasury);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(dave, 100 ether);
        vm.deal(eve, 100 ether);
    }

    // ============================================================
    // Free questions
    // ============================================================

    function test_freeQuestion_create() public {
        vm.prank(alice);
        uint256 id = core.createFreeQuestion(keccak256("free q"));
        assertEq(id, 1);
        (address author,, uint256 stake,,,,,,,,) = core.questions(id);
        assertEq(author, alice);
        assertEq(stake, 0);
    }

    function test_freeQuestion_answerMustBeFree() public {
        vm.prank(alice);
        uint256 qId = core.createFreeQuestion(keccak256("q"));
        vm.prank(bob);
        vm.expectRevert(NousCore.FreeQuestionPaidAnswer.selector);
        core.createAnswer(qId, keccak256("a"), 0.1 ether, 0);
    }

    function test_freeQuestion_freeAnswerWorks() public {
        vm.prank(alice);
        uint256 qId = core.createFreeQuestion(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0, 0);
        assertEq(aId, 1);
    }

    function test_freeQuestion_cantSlash() public {
        vm.prank(alice);
        uint256 qId = core.createFreeQuestion(keccak256("q"));
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert(NousCore.NotPaidQuestion.selector);
        core.claimSlash(qId);
    }

    function test_freeQuestion_cantExtend() public {
        vm.prank(alice);
        uint256 qId = core.createFreeQuestion(keccak256("q"));
        vm.prank(alice);
        vm.expectRevert(NousCore.NotPaidQuestion.selector);
        core.requestExtension{value: 0.005 ether}(qId);
    }

    function test_freeAnswer_cantUnlock() public {
        vm.prank(alice);
        uint256 qId = core.createFreeQuestion(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0, 0);
        vm.prank(charlie);
        vm.expectRevert(NousCore.AnswerIsFree.selector);
        core.unlockAnswer{value: 0.01 ether}(aId);
    }

    // ============================================================
    // Paid questions
    // ============================================================

    function test_paidQuestion_create() public {
        vm.prank(alice);
        uint256 id = core.createPaidQuestion{value: 0.01 ether}(keccak256("paid q"));
        (address author,, uint256 stake,,,,,,,,) = core.questions(id);
        assertEq(author, alice);
        assertEq(stake, 0.01 ether);
        assertTrue(core.isPaidQuestion(id));
    }

    function test_paidQuestion_insufficientStake() public {
        vm.prank(alice);
        vm.expectRevert(NousCore.InsufficientStake.selector);
        core.createPaidQuestion{value: 0.001 ether}(keccak256("cheap"));
    }

    function test_paidQuestion_freeAnswerAllowed() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("discussion"), 0, 0); // free discussion answer
        assertGt(aId, 0);
    }

    function test_paidQuestion_paidAnswerAllowed() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("premium"), 0.05 ether, 0);
        (,,,uint256 fee,,) = core.answers(aId);
        assertEq(fee, 0.05 ether);
    }

    // ============================================================
    // Unlock fee split: 65/15/5/5/10
    // ============================================================

    function test_unlock_splitNoCitation() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 1 ether, 0);
        vm.prank(charlie);
        core.unlockAnswer{value: 1 ether}(aId);

        // No citation, no fork: author gets 65+5+5=75%, questioner 15%, cobuild 10%
        assertEq(core.earnings(bob), 0.75 ether);
        assertEq(core.earnings(alice), 0.15 ether + 0.01 ether); // 15% + stake refund
        assertEq(core.coBuildPool(), 0.1 ether);
    }

    function test_unlock_splitWithCitation() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(dave);
        uint256 a1 = core.createAnswer(qId, keccak256("foundation"), 0.05 ether, 0);
        vm.prank(bob);
        uint256 a2 = core.createAnswer(qId, keccak256("builds on a1"), 1 ether, a1);

        vm.prank(charlie);
        core.unlockAnswer{value: 1 ether}(a2);

        // Bob (author): 65% + 5% fork(no fork) = 70%
        assertEq(core.earnings(bob), 0.7 ether);
        // Alice (questioner): 15% + stake refund
        assertEq(core.earnings(alice), 0.15 ether + 0.01 ether);
        // Dave (cited): 5%
        assertEq(core.earnings(dave), 0.05 ether);
        // Co-build: 10%
        assertEq(core.coBuildPool(), 0.1 ether);
    }

    // ============================================================
    // FIX: Stake refund on first unlock
    // ============================================================

    function test_stakeRefund_onFirstUnlock() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 1 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.1 ether, 0);

        // First unlock: stake refunded
        vm.prank(charlie);
        core.unlockAnswer{value: 0.1 ether}(aId);
        // Alice gets: 15% of 0.1 + 1 ETH stake = 1.015 ETH
        assertEq(core.earnings(alice), 0.015 ether + 1 ether);

        // Second unlock: no double refund
        address reader2 = address(0xB001);
        vm.deal(reader2, 10 ether);
        vm.prank(reader2);
        core.unlockAnswer{value: 0.1 ether}(aId);
        // Alice gets: previous 1.015 + just 15% of 0.1 = 1.03 ETH
        assertEq(core.earnings(alice), 1.015 ether + 0.015 ether);
    }

    // ============================================================
    // FIX: Can't unlock on slashed question
    // ============================================================

    function test_cantUnlockSlashedQuestion() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.05 ether, 0);
        vm.warp(block.timestamp + 31 days);
        core.claimSlash(qId);

        vm.prank(charlie);
        vm.expectRevert(NousCore.QuestionSlashedErr.selector);
        core.unlockAnswer{value: 0.05 ether}(aId);
    }

    function test_cantAnswerSlashedQuestion() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.warp(block.timestamp + 31 days);
        core.claimSlash(qId);

        vm.prank(bob);
        vm.expectRevert(NousCore.QuestionSlashedErr.selector);
        core.createAnswer(qId, keccak256("late"), 0.01 ether, 0);
    }

    // ============================================================
    // FIX: Fork invariant — free fork must be free, paid fork must stake
    // ============================================================

    function test_fork_paidParent_mustStake() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        vm.expectRevert(NousCore.InsufficientStake.selector);
        core.forkQuestion{value: 0}(qId, keccak256("fork"));
    }

    function test_fork_paidParent_stakeOk() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 forkId = core.forkQuestion{value: 0.01 ether}(qId, keccak256("fork"));
        assertTrue(core.isPaidQuestion(forkId));
    }

    function test_fork_freeParent_mustBeFree() public {
        vm.prank(alice);
        uint256 qId = core.createFreeQuestion(keccak256("q"));
        vm.prank(bob);
        vm.expectRevert(NousCore.InsufficientStake.selector);
        core.forkQuestion{value: 0.01 ether}(qId, keccak256("fork")); // can't pay on free fork
    }

    function test_fork_freeParent_freeOk() public {
        vm.prank(alice);
        uint256 qId = core.createFreeQuestion(keccak256("q"));
        vm.prank(bob);
        uint256 forkId = core.forkQuestion{value: 0}(qId, keccak256("fork"));
        assertFalse(core.isPaidQuestion(forkId));
    }

    function test_fork_royalty() public {
        vm.prank(alice);
        uint256 parentId = core.createPaidQuestion{value: 0.01 ether}(keccak256("parent"));
        vm.prank(bob);
        uint256 forkId = core.forkQuestion{value: 0.01 ether}(parentId, keccak256("child"));
        vm.prank(dave);
        uint256 aId = core.createAnswer(forkId, keccak256("a"), 1 ether, 0);

        vm.prank(charlie);
        core.unlockAnswer{value: 1 ether}(aId);

        // Alice (parent author) gets 5% fork royalty
        assertEq(core.earnings(alice), 0.05 ether);
        // Bob (fork questioner) gets 15% + stake refund
        assertEq(core.earnings(bob), 0.15 ether + 0.01 ether);
    }

    // ============================================================
    // FIX: Co-build pool — claimBounty is onlyOwner
    // ============================================================

    function test_cobuild_nonOwnerCantClaim() public {
        // Setup: create unlock to fund pool
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 1 ether, 0);
        vm.prank(charlie);
        core.unlockAnswer{value: 1 ether}(aId);
        assertEq(core.coBuildPool(), 0.1 ether);

        // Attacker creates and self-approves proposal (needs rep first)
        // Even if proposal gets approved, only owner can release funds
        vm.prank(founder);
        core.setProposalThreshold(1);

        vm.prank(bob); // bob has rep=1 from the unlock
        uint256 pId = core.createProposal(keccak256("steal"), 0.1 ether);
        vm.prank(bob);
        core.voteProposal(pId);

        // Bob tries to claim — reverts (not owner)
        vm.prank(bob);
        vm.expectRevert();
        core.claimBounty(pId, bob);

        // Owner can claim
        vm.prank(founder);
        core.claimBounty(pId, bob);
        assertEq(core.earnings(bob), 0.75 ether + 0.1 ether); // unlock earnings + bounty
    }

    // ============================================================
    // Reputation
    // ============================================================

    function test_reputation() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.01 ether, 0);

        for (uint160 i = 1; i <= 5; i++) {
            address reader = address(i + 5000);
            vm.deal(reader, 1 ether);
            vm.prank(reader);
            core.unlockAnswer{value: 0.01 ether}(aId);
        }
        assertEq(core.reputation(bob), 5);
    }

    // ============================================================
    // Questioner earns from ALL answers
    // ============================================================

    function test_questionerEarnsFromAllAnswers() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));

        vm.prank(bob);
        uint256 a1 = core.createAnswer(qId, keccak256("a1"), 0.1 ether, 0);
        vm.prank(dave);
        uint256 a2 = core.createAnswer(qId, keccak256("a2"), 0.2 ether, 0);

        vm.prank(charlie);
        core.unlockAnswer{value: 0.1 ether}(a1); // alice gets 15% = 0.015 + stake 0.01
        vm.prank(charlie);
        core.unlockAnswer{value: 0.2 ether}(a2); // alice gets 15% = 0.03 (no double refund)

        assertEq(core.earnings(alice), 0.015 ether + 0.01 ether + 0.03 ether);
    }

    // ============================================================
    // Slash + Extension
    // ============================================================

    function test_slash() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 1 ether}(keccak256("q"));
        vm.warp(block.timestamp + 31 days);
        core.claimSlash(qId);
        assertEq(core.earnings(alice), 0.5 ether);
    }

    function test_slash_hasUnlocks() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.01 ether, 0);
        vm.prank(charlie);
        core.unlockAnswer{value: 0.01 ether}(aId);
        vm.warp(block.timestamp + 31 days);
        vm.expectRevert(NousCore.HasUnlocks.selector);
        core.claimSlash(qId);
    }

    function test_extension() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(alice);
        core.requestExtension{value: 0.005 ether}(qId);
        (,,,, uint48 deadline, bool extended,,,,,) = core.questions(qId);
        assertTrue(extended);
        assertGt(deadline, uint48(block.timestamp + 60 days));
    }

    // ============================================================
    // Upvote + Pause
    // ============================================================

    function test_upvote() public {
        vm.prank(alice);
        uint256 qId = core.createFreeQuestion(keccak256("q"));
        vm.prank(bob);
        core.upvote(qId);
        assertTrue(core.hasVoted(bob, qId));
    }

    function test_upvote_double() public {
        vm.prank(alice);
        uint256 qId = core.createFreeQuestion(keccak256("q"));
        vm.prank(bob);
        core.upvote(qId);
        vm.prank(bob);
        vm.expectRevert(NousCore.AlreadyVoted.selector);
        core.upvote(qId);
    }

    function test_pause() public {
        vm.prank(founder);
        core.pause();
        vm.prank(alice);
        vm.expectRevert();
        core.createFreeQuestion(keccak256("q"));
    }

    // ============================================================
    // Withdraw
    // ============================================================

    function test_withdraw() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 1 ether, 0);
        vm.prank(charlie);
        core.unlockAnswer{value: 1 ether}(aId);

        uint256 before = bob.balance;
        vm.prank(bob);
        core.withdraw();
        assertEq(bob.balance - before, 0.75 ether); // 65% + 5% citation(none) + 5% fork(none)
    }

    function test_withdraw_nothing() public {
        vm.prank(alice);
        vm.expectRevert(NousCore.NothingToWithdraw.selector);
        core.withdraw();
    }

    // ============================================================
    // Self-unlock blocked
    // ============================================================

    function test_selfUnlock() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.05 ether, 0);
        vm.prank(bob);
        vm.expectRevert(NousCore.SelfUnlock.selector);
        core.unlockAnswer{value: 0.05 ether}(aId);
    }

    // ============================================================
    // Citation chain
    // ============================================================

    function test_citationChain() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(dave);
        uint256 a1 = core.createAnswer(qId, keccak256("foundation"), 0.05 ether, 0);
        vm.prank(bob);
        uint256 a2 = core.createAnswer(qId, keccak256("builds on a1"), 1 ether, a1);

        vm.prank(charlie);
        core.unlockAnswer{value: 1 ether}(a2);
        // Dave (cited) gets 5%
        assertEq(core.earnings(dave), 0.05 ether);
    }

    function test_invalidCitation() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        vm.expectRevert(NousCore.InvalidCitation.selector);
        core.createAnswer(qId, keccak256("a"), 0.1 ether, 999);
    }

    // ============================================================
    // SAFETY: forfeit stake + withdraw-when-paused + solvency
    // ============================================================

    function test_forfeitStake() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 1 ether}(keccak256("q"));

        // Alice wants out immediately — forfeits entire stake to co-build pool
        vm.prank(alice);
        core.forfeitStake(qId);

        assertEq(core.coBuildPool(), 1 ether);
        assertEq(core.earnings(alice), 0); // gets nothing back
    }

    function test_forfeitStake_notAuthor() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        vm.expectRevert(NousCore.NotAuthor.selector);
        core.forfeitStake(qId);
    }

    function test_forfeitStake_cantForfeitAfterUnlock() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.01 ether, 0);
        vm.prank(charlie);
        core.unlockAnswer{value: 0.01 ether}(aId);

        vm.prank(alice);
        vm.expectRevert(NousCore.HasUnlocks.selector);
        core.forfeitStake(qId);
    }

    function test_forfeitStake_cantForfeitAfterAnswer() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        // Someone answers — now forfeit is blocked to prevent griefing
        vm.prank(bob);
        core.createAnswer(qId, keccak256("effort"), 0.05 ether, 0);

        vm.prank(alice);
        vm.expectRevert(NousCore.HasUnlocks.selector);
        core.forfeitStake(qId);
    }

    function test_withdrawWorksWhenPaused() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 1 ether, 0);
        vm.prank(charlie);
        core.unlockAnswer{value: 1 ether}(aId);

        // Owner pauses contract
        vm.prank(founder);
        core.pause();

        // Bob can still withdraw — withdraw is NEVER paused
        uint256 before = bob.balance;
        vm.prank(bob);
        core.withdraw();
        assertGt(bob.balance, before);
    }

    function test_slashWorksWhenPaused() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 0.01 ether}(keccak256("q"));

        vm.prank(founder);
        core.pause();

        vm.warp(block.timestamp + 31 days);
        // Slash works even when paused
        core.claimSlash(qId);
        assertEq(core.earnings(alice), 0.005 ether);
    }

    function test_contractBalance() public {
        vm.prank(alice);
        uint256 qId = core.createPaidQuestion{value: 1 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.5 ether, 0);
        vm.prank(charlie);
        core.unlockAnswer{value: 0.5 ether}(aId);

        // Contract holds stake (1 ETH) + unlock fee (0.5 ETH) = 1.5 ETH
        assertEq(core.contractBalance(), 1.5 ether);
        assertGt(core.contractBalance(), core.coBuildPoolBalance());
    }
}
