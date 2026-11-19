// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PegzeusToken} from "../src/PegzeusToken.sol";

/// @notice Drives transfers, approvals and delegated transfers between a fixed set of holders.
/// Amounts are bounded to what the acting holder can move, so no call is expected to revert.
contract HolderHandler is Test {
    PegzeusToken public immutable token;
    address[] public holders;
    uint256 public calls;

    constructor(PegzeusToken token_, address[] memory holders_) {
        token = token_;
        holders = holders_;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _holder(fromSeed);
        address to = _holder(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
        calls++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _holder(ownerSeed);
        address spender = _holder(spenderSeed);
        vm.prank(owner);
        token.approve(spender, amount);
        calls++;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _holder(ownerSeed);
        address spender = _holder(spenderSeed);
        address to = _holder(toSeed);
        uint256 balance = token.balanceOf(owner);
        uint256 allowed = token.allowance(owner, spender);
        amount = bound(amount, 0, balance < allowed ? balance : allowed);
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        calls++;
    }

    function _holder(uint256 seed) private view returns (address) {
        return holders[seed % holders.length];
    }
}

contract PegzeusTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    PegzeusToken internal token;
    HolderHandler internal handler;

    function setUp() public {
        token = new PegzeusToken();
        address[] memory holders = new address[](5);
        for (uint256 i = 0; i < holders.length; i++) {
            holders[i] = address(uint160(0x1000 + i));
        }
        handler = new HolderHandler(token, holders);
        // Spread the supply unevenly; one holder starts empty.
        token.transfer(holders[0], SUPPLY / 2);
        token.transfer(holders[1], SUPPLY / 4);
        token.transfer(holders[2], SUPPLY / 8);
        token.transfer(holders[3], SUPPLY - SUPPLY / 2 - SUPPLY / 4 - SUPPLY / 8);
        targetContract(address(handler));
    }

    /// @dev The supply never grows and never shrinks: there is no mint and no burn.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    /// @dev Transfers only move tokens between holders: the balances always add up to the supply.
    function invariant_balancesSumToTheSupply() public view {
        uint256 sum;
        uint256 count = handler.holderCount();
        for (uint256 i = 0; i < count; i++) {
            sum += token.balanceOf(handler.holders(i));
        }
        assertEq(sum, SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }
}
