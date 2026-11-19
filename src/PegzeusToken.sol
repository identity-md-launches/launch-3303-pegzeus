// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Pegzeus (PEGZEUS)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 PEGZEUS (18 decimals) is minted
/// once, in the constructor, to the account that deploys the contract. Nothing can mint afterwards.
/// @dev Deliberately plain: no owner, no pause, no blacklist, no fee or burn on transfer, no mint,
/// no upgrade path, no constructor arguments. Every transfer moves exactly the amount it names, so
/// the launch flows (distributor, pool seed, swaps, remainder) need no exemptions. The Solidity
/// identifier is `PegzeusToken`; the token's own name and symbol are returned by `name()` and
/// `symbol()`.
contract PegzeusToken is ERC20 {
    /// @notice The entire supply, in minor units: 1,000,000,000 tokens with 18 decimals.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Mints `INITIAL_SUPPLY` to the deployer (`msg.sender`; on an IMD launch, the factory).
    constructor() ERC20("Pegzeus", "PEGZEUS") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
