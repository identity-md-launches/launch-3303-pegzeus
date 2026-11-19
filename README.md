# Pegzeus (PEGZEUS)

A fixed-supply ERC-20 token.

| Property        | Value                                                        |
| --------------- | ------------------------------------------------------------ |
| Name            | `Pegzeus`                                                    |
| Symbol          | `PEGZEUS`                                                    |
| Decimals        | `18`                                                         |
| Total supply    | `1,000,000,000` PEGZEUS = `1000000000000000000000000000` minor units |
| Solidity name   | `PegzeusToken` (`src/PegzeusToken.sol`)                      |
| Constructor     | no arguments                                                 |

The whole supply is minted once, in the constructor, to the account that deploys the contract
(`msg.sender`). Nothing can mint afterwards, and nothing can burn: the supply is constant for the
life of the contract.

## Design

`PegzeusToken` is OpenZeppelin's `ERC20` (v5.1.0) with a constructor that mints
`INITIAL_SUPPLY`. It adds nothing else, on purpose:

- **No owner or admin.** There is no `Ownable`, no role, no privileged address. The deployer's only
  advantage is that it starts with the supply.
- **No mint, no burn.** The supply cannot grow or shrink after deployment.
- **No pause, blacklist, freeze or seizure.** Only a holder, or a spender the holder approved, can
  move the holder's balance.
- **No fee, tax, reflection or rebase.** Every transfer moves exactly the amount it names, so
  balances always add up to the supply and integrations (pools, distributors, vaults) receive what
  they are sent.
- **No upgrade path, no proxy, no external calls.** The runtime code contains no `CALL`,
  `DELEGATECALL`, `CALLCODE`, `SELFDESTRUCT`, `CREATE` or `CREATE2` (a test scans for them), so
  there is no reentrancy surface.
- **No ETH.** The constructor and every function are non-payable and there is no `receive` or
  `fallback`, so plain ETH transfers to the token revert.

### Constants

| Constant         | Value                        | Where                  |
| ---------------- | ---------------------------- | ---------------------- |
| `INITIAL_SUPPLY` | `1_000_000_000 * 10 ** 18`   | `src/PegzeusToken.sol` |

Name, symbol and decimals are fixed in the code (decimals is OpenZeppelin's default of 18).

## Deployment parameters

The contract takes **no constructor arguments**. Whoever creates it receives the supply.

For the launch this was built for (values decided by the launch and the requester, recorded here
for reference; the launch manifest is written by a later step, not by this repository):

| Parameter                     | Value                                                        |
| ----------------------------- | ------------------------------------------------------------ |
| Chain                         | Ethereum mainnet (chain id 1)                                |
| Launch kind                   | custom token, no application contracts                       |
| `token.contract`              | `PegzeusToken`                                               |
| `token.name` / `token.symbol` | `Pegzeus` / `PEGZEUS`                                        |
| `token.decimals`              | `18`                                                         |
| `token.totalSupply`           | `1000000000000000000000000000`                               |
| `token.constructorArgs`       | none (`[]`)                                                  |
| Paired currency               | imdUSD, `0x61aaf8a992a3143e2b0c9cb0030b9fe702854a25` (18 decimals) |
| Pool fee / tick spacing       | `12500` (1.25%) / `60`                                       |
| `economics.poolBps`           | `8000` (80% of the supply seeds the pool)                    |
| `economics.initialMarketCapWei` | `20000000000000000000000` (20,000 imdUSD for the whole supply) |
| `economics.remainderTo`       | `0xbb85c1b7540d9e7b56f7a595fc1ff7dd07cb0823` (receives 10%)  |
| Swarm share                   | 10% of the supply, sent by the factory to the launch's MerkleDistributor |

On this launch the deployer is the launch factory: the constructor mints the whole supply to it,
and it pays all of it out (10% to the distributor, 80% into the pool, 10% to `remainderTo`).
Because the token has no transfer fee and no exemptions list, each of those flows arrives exact
without the token needing to know the factory, the pool manager or the distributor; that is why the
constructor takes none of them.

Build settings (`foundry.toml`): solc `0.8.26`, EVM version `cancun`, optimizer on with 200 runs,
`bytecode_hash = "none"` so the deployed bytes are reproducible without a metadata hash.

## Assumptions

- "Minted to the deployer" means `msg.sender` of the creation, never `tx.origin`. When a factory
  creates the token, the factory holds the supply and is responsible for distributing it.
- The brief asks for a token with a name, symbol and fixed supply and nothing more, so no optional
  extension was added: no `permit` (EIP-2612), no votes/governance, no burn function. Approvals are
  the standard `approve` / `transferFrom`.
- Standard ERC-20 behaviour is kept as OpenZeppelin implements it: transfers to the zero address
  revert, an allowance of `type(uint256).max` is treated as unlimited and not decremented, and
  failures revert with the ERC-6093 custom errors (`ERC20InsufficientBalance`,
  `ERC20InsufficientAllowance`, `ERC20InvalidReceiver`, `ERC20InvalidSpender`, ...).
- 18 decimals, as stated in the brief.

## Operational responsibilities

There is nothing to operate: the contract has no owner, no settings and no privileged functions.

- **Deployer.** Receives the entire supply and is solely responsible for distributing it. On the
  IMD launch that is the factory, which pays it all out in the launch transaction; if the contract
  is deployed by hand instead, the deploying wallet holds 1,000,000,000 PEGZEUS and should be
  secured accordingly (a multisig is advisable).
- **Holders.** Tokens sent to an address nobody controls, including the token contract's own
  address, cannot be recovered: there is no rescue function and no admin who could add one.
- **Approvals.** As with any ERC-20, changing a non-zero allowance to another non-zero value can be
  front-run by the spender; set it to zero first, or approve only the amount needed.
- **Integrators.** Read `decimals()` rather than assuming it. The token is not a rebasing or
  fee-on-transfer token, so no special handling is needed.

## After launch

No post-deployment configuration exists. There are no setters to call, no roles to hand over and no
ownership to transfer or renounce.

Open items that belong to the deployer and launch policy, not to this repository: deploying the
contract, verifying the source on a block explorer, and writing the launch manifest.

## Tests

```
forge build
forge test
forge fmt --check
```

- `test/PegzeusToken.t.sol` — unit and fuzz tests: metadata and supply; the supply goes to the
  creating contract and not `tx.origin`; launch-style payouts (10% / 80% / 10%) arrive and leave
  exact; `transfer`, `approve` and `transferFrom` success paths with events; failure paths
  (above balance, empty account, zero receiver, zero spender, missing or insufficient allowance,
  deployer trying to move a holder's balance); no mint / owner / upgrade / pause / freeze / burn
  entry point exists for the deployer or a stranger; ETH and unknown calls are rejected; runtime
  bytecode scan for forbidden opcodes.
- `test/PegzeusToken.invariant.t.sol` — invariant tests driving random transfers, approvals and
  delegated transfers between holders: the total supply never changes and balances always sum to
  it.

The tests read no environment variables, use no fork, `ffi` or filesystem access, and do not depend
on execution order.

Passing tests are not a security audit. No static analyser (Slither, Mythril) was run as part of
this work; the contract's own logic is a constructor of one line over an unmodified, widely audited
OpenZeppelin `ERC20`.

## Dependencies

Vendored as ordinary files under `lib/` (no git submodules), so the project builds offline:

- `lib/openzeppelin-contracts` — OpenZeppelin Contracts v5.1.0 (MIT), only the five files `ERC20`
  needs: `ERC20.sol`, `IERC20.sol`, `IERC20Metadata.sol`, `Context.sol`, `draft-IERC6093.sol`.
- `lib/forge-std` — forge-std v1.9.7 (MIT / Apache-2.0), used by tests only.

## License

MIT.
