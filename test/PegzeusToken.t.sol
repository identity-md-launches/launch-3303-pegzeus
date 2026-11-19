// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PegzeusToken} from "../src/PegzeusToken.sol";

/// @notice Stands in for a deploying factory: creates the token with CREATE2 from its creation
/// code, as the launch does, and pays the supply out.
contract FactoryStandIn {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function move(IERC20 token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract PegzeusTokenTest is Test {
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

    // ------------------------------------------------------------------ deployment

    function test_metadata() public view {
        assertEq(token.name(), "Pegzeus");
        assertEq(token.symbol(), "PEGZEUS");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsOneBillionWith18Decimals() public view {
        assertEq(token.INITIAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_wholeSupplyIsMintedToTheDeployer() public view {
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_constructorEmitsTheMintTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), ALICE, SUPPLY);
        vm.prank(ALICE);
        PegzeusToken fresh = new PegzeusToken();
        assertEq(fresh.balanceOf(ALICE), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    /// @dev The supply goes to msg.sender (the creating contract), never to tx.origin.
    function test_supplyGoesToTheCreatingFactoryNotTheOrigin() public {
        FactoryStandIn factory = new FactoryStandIn();
        address caller = address(0xCA11E4);
        address origin = address(0x0419);
        vm.prank(caller, origin);
        PegzeusToken launched = PegzeusToken(factory.deploy(type(PegzeusToken).creationCode, bytes32(uint256(7))));
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(caller), 0);
        assertEq(launched.balanceOf(origin), 0);
    }

    /// @dev The launch pays the supply out in three parts; each must arrive exactly, and claims and
    /// pool withdrawals must leave exactly, because no transfer carries a fee or a burn.
    function test_launchFlowsMoveExactAmounts() public {
        FactoryStandIn factory = new FactoryStandIn();
        PegzeusToken launched = PegzeusToken(factory.deploy(type(PegzeusToken).creationCode, bytes32(0)));
        address distributor = address(0xD157);
        address pool = address(0x9001);
        address remainderTo = address(0x4E3A);
        address claimant = address(0xC1A1);

        uint256 swarm = SUPPLY / 10;
        uint256 seed = (SUPPLY * 8_000) / 10_000;
        uint256 rest = SUPPLY - swarm - seed;

        assertTrue(factory.move(launched, distributor, swarm));
        assertTrue(factory.move(launched, pool, seed));
        assertTrue(factory.move(launched, remainderTo, rest));
        assertEq(launched.balanceOf(distributor), swarm);
        assertEq(launched.balanceOf(pool), seed);
        assertEq(launched.balanceOf(remainderTo), rest);
        assertEq(launched.balanceOf(address(factory)), 0);

        vm.prank(distributor);
        assertTrue(launched.transfer(claimant, swarm));
        assertEq(launched.balanceOf(claimant), swarm);
        assertEq(launched.balanceOf(distributor), 0);

        vm.prank(pool);
        assertTrue(launched.transfer(claimant, 1 ether));
        assertEq(launched.balanceOf(claimant), swarm + 1 ether);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function test_constructorTakesNoArguments() public {
        // Deploying the bare creation code works: nothing has to be appended to it.
        bytes memory code = type(PegzeusToken).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        assertTrue(deployed != address(0));
        assertEq(PegzeusToken(deployed).balanceOf(address(this)), SUPPLY);
    }

    function test_constructorRejectsEther() public {
        bytes memory code = type(PegzeusToken).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create(1, add(code, 32), mload(code))
        }
        assertEq(deployed, address(0));
    }

    // ------------------------------------------------------------------ transfer

    function test_transferMovesExactAmount() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(DEPLOYER, ALICE, 123 ether);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(ALICE, 123 ether));
        assertEq(token.balanceOf(ALICE), 123 ether);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 123 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferOfWholeBalanceAndZero() public {
        vm.startPrank(DEPLOYER);
        assertTrue(token.transfer(ALICE, 0));
        assertEq(token.balanceOf(ALICE), 0);
        assertTrue(token.transfer(ALICE, SUPPLY));
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), 0);
    }

    function test_transferToSelfChangesNothing() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(DEPLOYER, 5 ether));
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRevertsAboveBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10 ether, 11 ether)
        );
        vm.prank(ALICE);
        token.transfer(BOB, 11 ether);
        assertEq(token.balanceOf(ALICE), 10 ether);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 0, 1));
        vm.prank(BOB);
        token.transfer(ALICE, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(DEPLOYER);
        token.transfer(address(0), 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRevertsAboveTotalSupply() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, SUPPLY + 1)
        );
        vm.prank(DEPLOYER);
        token.transfer(ALICE, SUPPLY + 1);
    }

    // ------------------------------------------------------------------ approve / transferFrom

    function test_approveSetsAndOverwritesAllowance() public {
        vm.expectEmit(true, true, false, true);
        emit Approval(DEPLOYER, ALICE, 50 ether);
        vm.startPrank(DEPLOYER);
        assertTrue(token.approve(ALICE, 50 ether));
        assertEq(token.allowance(DEPLOYER, ALICE), 50 ether);
        assertTrue(token.approve(ALICE, 7 ether));
        assertEq(token.allowance(DEPLOYER, ALICE), 7 ether);
        assertTrue(token.approve(ALICE, 0));
        vm.stopPrank();
        assertEq(token.allowance(DEPLOYER, ALICE), 0);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(DEPLOYER);
        token.approve(address(0), 1 ether);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 50 ether);
        vm.expectEmit(true, true, false, true);
        emit Transfer(DEPLOYER, BOB, 20 ether);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(DEPLOYER, BOB, 20 ether));
        assertEq(token.balanceOf(BOB), 20 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 20 ether);
        assertEq(token.allowance(DEPLOYER, ALICE), 30 ether);
    }

    function test_transferFromLeavesInfiniteAllowanceUntouched() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 20 ether);
        assertEq(token.allowance(DEPLOYER, ALICE), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, ALICE, 1);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    function test_transferFromRevertsAboveAllowance() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 5 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 5 ether, 5 ether + 1)
        );
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, 5 ether + 1);
        assertEq(token.allowance(DEPLOYER, ALICE), 5 ether);
    }

    function test_transferFromRevertsAboveOwnersBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 3 ether);
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 3 ether, 4 ether));
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 4 ether);
        assertEq(token.allowance(ALICE, BOB), 10 ether);
    }

    function test_transferFromRevertsToZeroAddress() public {
        vm.prank(DEPLOYER);
        token.approve(ALICE, 5 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, address(0), 1 ether);
    }

    /// @dev An allowance is the owner's to give: the deployer has no standing power over holders.
    function test_deployerCannotMoveAHoldersBalance() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, DEPLOYER, 0, 1));
        vm.prank(DEPLOYER);
        token.transferFrom(ALICE, DEPLOYER, 1);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }

    // ------------------------------------------------------------------ no privileged surface

    /// @dev None of the usual mint, ownership, upgrade, pause, freeze or burn entry points exist.
    /// Each call fails for the deployer and for a stranger, and changes nothing.
    function test_noAdminMintPauseOrFreezeFunctionExists() public {
        vm.prank(DEPLOYER);
        token.transfer(ALICE, 1_000 ether);
        string[24] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "renounceOwnership()",
            "owner()",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "lock(address)",
            "setTransfersEnabled(bool)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        address[2] memory callers = [DEPLOYER, BOB];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, uint256(1));
            for (uint256 j = 0; j < callers.length; j++) {
                vm.prank(callers[j]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(ALICE), 1_000 ether, signatures[i]);
            assertEq(token.balanceOf(BOB), 0, signatures[i]);
        }
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 500 ether));
        assertEq(token.balanceOf(BOB), 500 ether);
    }

    function test_rejectsEtherAndUnknownCalls() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(token).call{value: 1 wei}("");
        assertFalse(ok);
        (ok,) = address(token).call("");
        assertFalse(ok);
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    /// @dev Scans what execution can reach (from the start or a JUMPDEST up to a terminating
    /// opcode) for DELEGATECALL, CALLCODE and SELFDESTRUCT, and also for CALL, CREATE and CREATE2:
    /// the token calls nothing and deploys nothing.
    function test_runtimeCodeHasNoCallDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        bool reachable = true;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
                assertTrue(op != 0xF1, "CALL");
                assertTrue(op != 0xF0, "CREATE");
                assertTrue(op != 0xF5, "CREATE2");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ------------------------------------------------------------------ fuzz

    function testFuzz_transferConservesBalances(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, 0, SUPPLY);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(to, amount));
        if (to == DEPLOYER) {
            assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        } else {
            assertEq(token.balanceOf(to), toBefore + amount);
            assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferRevertsAboveBalance(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, held + 1, type(uint256).max);
        vm.prank(DEPLOYER);
        token.transfer(ALICE, held);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, amount));
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        assertEq(token.balanceOf(ALICE), held);
    }

    function testFuzz_transferFromSpendsExactlyTheAmount(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, type(uint256).max - 1);
        amount = bound(amount, 0, allowed < SUPPLY ? allowed : SUPPLY);
        vm.prank(DEPLOYER);
        token.approve(ALICE, allowed);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(DEPLOYER, BOB, amount));
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - amount);
        assertEq(token.allowance(DEPLOYER, ALICE), allowed - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromRevertsAboveAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, type(uint256).max - 1);
        amount = bound(amount, allowed + 1, type(uint256).max);
        vm.prank(DEPLOYER);
        token.approve(ALICE, allowed);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, allowed, amount)
        );
        vm.prank(ALICE);
        token.transferFrom(DEPLOYER, BOB, amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.allowance(DEPLOYER, ALICE), allowed);
    }

    function testFuzz_strangerCannotSpendWithoutAllowance(address stranger, uint256 amount) public {
        vm.assume(stranger != DEPLOYER && stranger != address(0));
        amount = bound(amount, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        vm.prank(stranger);
        token.transferFrom(DEPLOYER, stranger, amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }
}
