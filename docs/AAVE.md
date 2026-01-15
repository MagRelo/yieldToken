# Aave Integration

## Version

**Aave V3** - We are using Aave V3 for this project.

## Networks

- **Production**: Base Network
- **Testing**: Base Sepolia

## Contract Addresses

Reference: https://aave.com/docs/resources/addresses

### Base Mainnet (V3)

| Contract              | Address                                    |
| --------------------- | ------------------------------------------ |
| Pool                  | 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5 |
| PoolAddressesProvider | 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D |

### Base Sepolia (V3 Testnet)

| Contract              | Address                                    |
| --------------------- | ------------------------------------------ |
| Pool                  | 0x07eA79F68B2B3df564D0A34F8e19D9B1e339814b |
| PoolAddressesProvider | 0xd449FeD49d9C443688d6816fE6872F21402e41de |

## Smart Contracts Reference

Documentation: https://aave.com/docs/aave-v3/smart-contracts

### Key V3 Contracts

- **Pool** - Main entry point for user interactions (supply, borrow, withdraw, repay)
- **PoolAddressesProvider** - Registry for protocol components
- **AToken** - Yield-generating tokens minted on supply
- **VariableDebtToken** - Non-transferable tokens representing borrow positions
- **AaveOracle** - Asset price registry

## Integration Details

### Supply

```solidity
pool.supply(asset, amount, onBehalfOf, referralCode);
```

- `asset`: Address of the underlying asset (e.g., USDC)
- `amount`: Amount to supply
- `onBehalfOf`: Address that will receive the aTokens
- `referralCode`: Referral code (use 0 if not applicable)

### Withdraw

```solidity
uint256 withdrawn = pool.withdraw(asset, amount, to);
```

- `asset`: Address of the underlying asset
- `amount`: Amount to withdraw (use `type(uint256).max` for full balance)
- `to`: Address that will receive the underlying asset
- Returns: The actual amount withdrawn

### Reserve Configuration

Use `pool.getConfiguration(asset)` to get the reserve configuration bitmap. Use the `ReserveConfiguration` library to decode:

- `getPaused()` - Check if reserve is paused
- `getFrozen()` - Check if reserve is frozen
- `getActive()` - Check if reserve is active

## Fork Tests

Fork tests verify the integration works correctly against real USDC and Aave V3 contracts on Base networks.

### Test Files

- `test/DepositManagerBaseFork.t.sol` - Tests against Base Mainnet
- `test/DepositManagerBaseSepoliaFork.t.sol` - Tests against Base Sepolia testnet

### Running Fork Tests

**Base Mainnet:**

```bash
forge test --match-contract DepositManagerBaseForkTest --fork-url $BASE_RPC_URL --fork-block-number 20000000 -vvv
```

**Base Sepolia:**

```bash
forge test --match-contract DepositManagerBaseSepoliaForkTest --fork-url $BASE_SEPOLIA_RPC_URL -vvv
```

### Environment Variables

Copy `.env.example` to `.env` and set your RPC URLs:

```bash
cp .env.example .env
source .env
```

Example `.env` contents:

```bash
# RPC URLs for fork testing
BASE_RPC_URL="https://mainnet.base.org"
BASE_SEPOLIA_RPC_URL="https://sepolia.base.org"

# Or use a provider for better rate limits:
# BASE_RPC_URL="https://base-mainnet.g.alchemy.com/v2/YOUR_API_KEY"
# BASE_SEPOLIA_RPC_URL="https://base-sepolia.g.alchemy.com/v2/YOUR_API_KEY"
```

### What the Fork Tests Verify

1. USDC token exists and has correct decimals
2. Aave V3 Pool exists and has USDC reserve configured
3. Deposits transfer USDC to Aave and mint platform tokens
4. Withdrawals burn platform tokens and return USDC from Aave
5. Full deposit/withdraw cycles maintain 1:1 backing
6. All view functions return correct data from live contracts
