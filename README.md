# TidepoolHub (slice)

Singleton ERC-1155 bonding-curve hub with USDC collateral.

- Linear curve: `P(s)=M·s`, `R(s)=M·s²/2`, `M=1e15`
- `buy(usdcAmount)` / `sell(shares)` with sell paying `min(grossRefund, reserve)`
- OpenZeppelin ERC1155 + SafeERC20 + ReentrancyGuard

## Setup

```bash
# Foundry must be on PATH (e.g. ~/.foundry/bin)
./scripts/bootstrap.sh
# or manually:
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2
```

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
