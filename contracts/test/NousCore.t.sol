// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/NousCore.sol";

contract NousCoreTest is Test {
    NousCore core;
    address founder = address(0xF001);
    address treasury = address(0xF002);
    address alice = address(0xA001);
    address bob = address(0xA002);
    address charlie = address(0xA003);

    function setUp() public {
        vm.prank(founder);
        core = new NousCore(treasury);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(charlie, 10 ether);
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

    // --- createAnswer ---

    function test_createAnswer() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.05 ether);
        assertEq(aId, 1);
        (uint256 questionId, address author,, uint256 fee) = core.answers(aId);
        assertEq(questionId, qId);
        assertEq(author, bob);
        assertEq(fee, 0.05 ether);
    }

    function test_createAnswer_questionNotFound() public {
        vm.prank(bob);
        vm.expectRevert(NousCore.QuestionNotFound.selector);
        core.createAnswer(999, keccak256("orphan"), 0.05 ether);
    }

    // --- unlockAnswer ---

    function test_unlockAnswer_split() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 1 ether);

        vm.prank(charlie);
        core.unlockAnswer{value: 1 ether}(aId);

        assertTrue(core.isUnlocked(charlie, aId));
        assertEq(core.earnings(bob), 0.95 ether);      // 95%
        assertEq(core.earnings(treasury), 0.05 ether);  // 5%
    }

    function test_unlockAnswer_selfUnlock() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.05 ether);
        vm.prank(bob);
        vm.expectRevert(NousCore.SelfUnlock.selector);
        core.unlockAnswer{value: 0.05 ether}(aId);
    }

    function test_unlockAnswer_alreadyUnlocked() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.05 ether);
        vm.prank(charlie);
        core.unlockAnswer{value: 0.05 ether}(aId);
        vm.prank(charlie);
        vm.expectRevert(NousCore.AlreadyUnlocked.selector);
        core.unlockAnswer{value: 0.05 ether}(aId);
    }

    function test_unlockAnswer_insufficientPayment() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.05 ether);
        vm.prank(charlie);
        vm.expectRevert(NousCore.InsufficientPayment.selector);
        core.unlockAnswer{value: 0.01 ether}(aId);
    }

    // --- withdraw ---

    function test_withdraw() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 1 ether);
        vm.prank(charlie);
        core.unlockAnswer{value: 1 ether}(aId);

        uint256 before = bob.balance;
        vm.prank(bob);
        core.withdraw();
        assertEq(bob.balance - before, 0.95 ether);
    }

    function test_withdraw_nothing() public {
        vm.prank(alice);
        vm.expectRevert(NousCore.NothingToWithdraw.selector);
        core.withdraw();
    }

    // --- claimSlash ---

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
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.01 ether);
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

    // --- requestExtension ---

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

    function test_pause_blocks_operations() public {
        vm.prank(founder);
        core.pause();
        vm.prank(alice);
        vm.expectRevert();
        core.createQuestion{value: 0.01 ether}(keccak256("q"));
    }

    // --- multiple unlocks accumulate ---

    function test_multipleUnlocks() public {
        vm.prank(alice);
        uint256 qId = core.createQuestion{value: 0.01 ether}(keccak256("q"));
        vm.prank(bob);
        uint256 aId = core.createAnswer(qId, keccak256("a"), 0.1 ether);

        for (uint160 i = 1; i <= 5; i++) {
            address reader = address(i + 3000);
            vm.deal(reader, 1 ether);
            vm.prank(reader);
            core.unlockAnswer{value: 0.1 ether}(aId);
        }

        // Bob earns 95% of 5 × 0.1 = 0.475 ETH
        assertEq(core.earnings(bob), 0.475 ether);
        // Treasury earns 5% of 0.5 = 0.025 ETH
        assertEq(core.earnings(treasury), 0.025 ether);
        // Question has 5 unlocks
        (,,,,,,,uint32 cnt,) = core.questions(qId);
        assertEq(cnt, 5);
    }
}
