// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PegzeusToken} from "../src/PegzeusToken.sol";

/// @notice Drives the token with valid and invalid calls in random order. It keeps its own model
/// (ghost balances and allowances) and checks every call against it: a valid call must move exactly
/// what it names, and an invalid call must revert with the right error and change nothing.
contract GhostHandler is Test {
    PegzeusToken public immutable token;
    address[] public actors;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public ghostMoved; // total value moved by successful transfers
    uint256 public okCalls;
    uint256 public failedCalls;

    constructor(PegzeusToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
        for (uint256 i; i < actors_.length; ++i) {
            ghostBalance[actors_[i]] = token_.balanceOf(actors_[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---------------------------------------------------------------- valid calls

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
        okCalls++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (infinite) amount = type(uint256).max;
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner][spender] = amount;
        okCalls++;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 bal = ghostBalance[owner];
        amount = bound(amount, 0, bal < allowed ? bal : allowed);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
        _move(owner, to, amount);
        okCalls++;
    }

    // ---------------------------------------------------------------- invalid calls

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 bal = ghostBalance[from];
        uint256 amount = bal + bound(excess, 1, type(uint256).max - bal);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, bal, amount));
        token.transfer(to, amount);
        failedCalls++;
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        failedCalls++;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
        failedCalls++;
    }

    function transferFromOverAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed == type(uint256).max) return; // an infinite allowance cannot be exceeded
        uint256 amount = allowed + bound(excess, 1, type(uint256).max - allowed);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        token.transferFrom(owner, to, amount);
        failedCalls++;
    }

    function transferFromOverBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 excess)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 bal = ghostBalance[owner];
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed <= bal) return; // the allowance check would fire first
        uint256 amount = bal + bound(excess, 1, allowed - bal);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, bal, amount));
        token.transferFrom(owner, to, amount);
        failedCalls++;
    }

    function sendEther(uint256 fromSeed, uint256 value) external {
        address from = _actor(fromSeed);
        value = bound(value, 1, 1 ether);
        vm.deal(from, value);
        vm.prank(from);
        (bool ok,) = address(token).call{value: value}("");
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0);
        failedCalls++;
    }

    // ---------------------------------------------------------------- helpers

    function _move(address from, address to, uint256 amount) private {
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostMoved += amount;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }
}

contract PegzeusTokenGhostInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    PegzeusToken internal token;
    GhostHandler internal handler;
    address internal constant DEPLOYER = address(0xFAC7);

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new PegzeusToken();

        address[] memory actors = new address[](6);
        actors[0] = DEPLOYER; // starts with the whole supply
        for (uint256 i = 1; i < actors.length; i++) {
            actors[i] = address(uint160(0xA000 + i));
        }
        // a contract actor too: the token must treat it like any account
        actors[5] = address(new Sink());

        vm.startPrank(DEPLOYER);
        token.transfer(actors[1], SUPPLY / 3);
        token.transfer(actors[2], 1); // one wei holder
        vm.stopPrank();

        handler = new GhostHandler(token, actors);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    function invariant_supplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 128
    function invariant_balancesMatchTheModelAndSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            assertEq(token.balanceOf(a), handler.ghostBalance(a), "balance drifted from the model");
            sum += token.balanceOf(a);
        }
        assertEq(sum, SUPPLY, "balances do not add up to the supply");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    /// forge-config: default.invariant.runs = 128
    function invariant_allowancesMatchTheModel() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address o = handler.actors(i);
                address s = handler.actors(j);
                assertEq(token.allowance(o, s), handler.ghostAllowance(o, s), "allowance drifted from the model");
            }
        }
    }

    /// forge-config: default.invariant.runs = 128
    function invariant_tokenNeverHoldsEther() public view {
        assertEq(address(token).balance, 0);
    }
}

contract Sink {}
