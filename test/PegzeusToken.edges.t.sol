// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PegzeusToken} from "../src/PegzeusToken.sol";

/// @notice Edge cases the main suite does not pin: zero amounts, one wei, the maximum allowance,
/// self-spending, repeated calls, and the events (or their absence) on each path.
contract PegzeusTokenEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    PegzeusToken internal token;
    address internal constant DEPLOYER = address(0xD3910);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new PegzeusToken();
    }

    function test_twoDeploymentsAreIndependent() public {
        vm.prank(ALICE);
        PegzeusToken other = new PegzeusToken();
        assertEq(other.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(other.balanceOf(DEPLOYER), 0);
        assertEq(token.totalSupply() + other.totalSupply(), 2 * SUPPLY);
    }

    function test_oneWeiTransfer() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1);
        assertEq(token.balanceOf(ALICE), 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1, 2));
        token.transfer(BOB, 2);
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 1);
    }

    function test_zeroTransferEmitsAndChangesNothing() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_zeroTransferToZeroAddressStillReverts() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
    }

    function test_transferFromZeroAmountNeedsNoAllowance() public {
        vm.prank(BOB);
        assertTrue(token.transferFrom(DEPLOYER, CAROL, 0));
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.allowance(DEPLOYER, BOB), 0);
    }

    function test_ownerCannotTransferFromItselfWithoutApproval() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, DEPLOYER, 0, 1));
        token.transferFrom(DEPLOYER, ALICE, 1);
    }

    function test_selfApprovalLetsOwnerUseTransferFrom() public {
        vm.startPrank(DEPLOYER);
        token.approve(DEPLOYER, 5);
        token.transferFrom(DEPLOYER, ALICE, 5);
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, DEPLOYER), 0);
        assertEq(token.balanceOf(ALICE), 5);
    }

    function test_approveEmitsApproval() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(ALICE, BOB, 42);
        vm.prank(ALICE);
        assertTrue(token.approve(BOB, 42));
    }

    function test_approveWithoutBalanceIsAllowedButCannotBeSpent() public {
        vm.prank(ALICE);
        token.approve(BOB, 10);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 10));
        token.transferFrom(ALICE, CAROL, 10);
        assertEq(token.allowance(ALICE, BOB), 10, "a failed transferFrom must not consume allowance");
    }

    function test_approveToZeroRevokes() public {
        vm.startPrank(DEPLOYER);
        token.approve(BOB, 100);
        token.approve(BOB, 0);
        vm.stopPrank();
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(DEPLOYER, BOB, 1);
    }

    function test_transferFromEmitsTransferButNoApproval() public {
        vm.prank(DEPLOYER);
        token.approve(BOB, 100);
        vm.recordLogs();
        vm.prank(BOB);
        token.transferFrom(DEPLOYER, CAROL, 60);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(DEPLOYER))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(CAROL))));
        assertEq(abi.decode(logs[0].data, (uint256)), 60);
        assertEq(token.allowance(DEPLOYER, BOB), 40);
    }

    function test_allowanceOneBelowMaxIsFinite() public {
        uint256 allowed = type(uint256).max - 1;
        vm.prank(DEPLOYER);
        token.approve(BOB, allowed);
        vm.prank(BOB);
        token.transferFrom(DEPLOYER, CAROL, 7);
        assertEq(token.allowance(DEPLOYER, BOB), allowed - 7);
    }

    function test_infiniteAllowanceSpendsWholeSupply() public {
        vm.prank(DEPLOYER);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(DEPLOYER, CAROL, SUPPLY);
        assertEq(token.balanceOf(CAROL), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), 0);
        assertEq(token.allowance(DEPLOYER, BOB), type(uint256).max);
    }

    function test_exactAllowanceCanBeSpentOnceOnly() public {
        vm.prank(DEPLOYER);
        token.approve(BOB, 3 ether);
        vm.prank(BOB);
        token.transferFrom(DEPLOYER, BOB, 3 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 3 ether));
        token.transferFrom(DEPLOYER, BOB, 3 ether);
        assertEq(token.balanceOf(BOB), 3 ether);
    }

    function test_allowanceIsPerSpender() public {
        vm.prank(DEPLOYER);
        token.approve(BOB, 10);
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, CAROL, 0, 10));
        token.transferFrom(DEPLOYER, CAROL, 10);
        assertEq(token.allowance(DEPLOYER, BOB), 10);
    }

    function test_transferFromToZeroDoesNotConsumeAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(BOB, 10);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(DEPLOYER, address(0), 10);
        assertEq(token.allowance(DEPLOYER, BOB), 10);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    function test_noBurnOrMintSelectors() public {
        bytes4[6] memory sels = [
            bytes4(keccak256("burn(uint256)")),
            bytes4(keccak256("burnFrom(address,uint256)")),
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("mint(uint256)")),
            bytes4(keccak256("increaseAllowance(address,uint256)")),
            bytes4(keccak256("decreaseAllowance(address,uint256)"))
        ];
        for (uint256 i; i < sels.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(sels[i], ALICE, 1));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- fuzz

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_roundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, amount);
        vm.prank(ALICE);
        token.transfer(DEPLOYER, amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveOverwritesAnyValue(uint256 first, uint256 second) public {
        vm.startPrank(ALICE);
        token.approve(BOB, first);
        assertEq(token.allowance(ALICE, BOB), first);
        token.approve(BOB, second);
        vm.stopPrank();
        assertEq(token.allowance(ALICE, BOB), second);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splitSpendEqualsWholeSpend(uint256 allowed, uint256 a, uint256 b) public {
        allowed = bound(allowed, 0, SUPPLY);
        a = bound(a, 0, allowed);
        b = bound(b, 0, allowed - a);
        vm.prank(DEPLOYER);
        token.approve(BOB, allowed);
        vm.startPrank(BOB);
        token.transferFrom(DEPLOYER, CAROL, a);
        token.transferFrom(DEPLOYER, CAROL, b);
        vm.stopPrank();
        assertEq(token.balanceOf(CAROL), a + b);
        assertEq(token.allowance(DEPLOYER, BOB), allowed - a - b);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - a - b);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_failedTransferLeavesStateUntouched(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 1, type(uint256).max);
        // ALICE holds nothing, so every non-zero transfer fails
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, amount));
        token.transfer(to, amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(to), to == DEPLOYER ? SUPPLY : 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
