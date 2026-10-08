# TidepoolHub (slice)

Singleton ERC-1155 bonding-curve hub with USDC collateral.

- Linear curve: `P(s)=M·s`, `R(s)=M·s²/2`, `M=1e15`
- `buy(usdcAmount)` / `sell(shares)` with sell paying `min(grossRefund, reserve)`
- OpenZeppelin ERC1155 + SafeERC20 + ReentrancyGuard

## Setup

Dependencies (`forge-std`, `openzeppelin-contracts`) are pinned as git
submodules under `lib/`. The pinned OpenZeppelin commit (package version 5.7.0)
needs solc `^0.8.24` and the Cancun EVM, which `foundry.toml` already sets, so
no extra compiler flags are needed.

```bash
# Foundry must be on PATH (e.g. ~/.foundry/bin)
git clone --recursive https://github.com/brandonbehbahani/tidepool.git
# or, in an existing clone (a plain clone leaves lib/ empty):
git submodule update --init --recursive
```

Do not `forge install` OpenZeppelin v5.0.2; that older release does not match
the pinned submodule.

## Test

```bash
forge test -vv
```

## Layout

```
foundry.toml
remappings.txt
scripts/bootstrap.sh
src/TidepoolHub.sol
src/libraries/CurveMath.sol
src/mocks/MockUSDC.sol
test/TidepoolHub.t.sol
```

Out of scope for this slice: Buffer, Staker, deploy scripts.
