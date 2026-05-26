# LocalUSDT — Non-Custodial USDT Escrow Contracts

> **Live at [localusdt.app](https://localusdt.app)** · [Plain-language contract explainer](https://localusdt.app/contracts)

Non-custodial escrow smart contracts for peer-to-peer USDT trading on **Tron (TRC-20)**, **Ethereum (ERC-20)**, and **BNB Smart Chain (BEP-20)**.

Adapted from the battle-tested [LocalCryptos](https://github.com/aspect-mining/localethereum/tree/master/contracts) ETH escrow architecture, re-engineered for ERC-20 USDT.

---

## Security Model

The contract enforces five rules that **cannot be overridden by anyone** — not the platform owner, not the arbitrator, not LocalUSDT staff:

| # | Rule | Enforced by |
|---|------|-------------|
| 1 | The seller can release USDT to the buyer at any time |`release()` /`doRelease()` |
| 2 | The buyer can cancel and return USDT to the seller |`buyerCancel()` /`doBuyerCancel()` |
| 3 | The seller can cancel if the payment window expires |`sellerCancel()` /`doSellerCancel()` |
| 4 | The arbitrator can direct USDT **only** to the buyer or seller — never to themselves |`resolveDispute()` hardcodes`_buyer` and`_seller` as recipients |
| 5 | The platform **cannot** withdraw escrowed USDT under any circumstances | No function exists to do so.`withdrawFees()` is bounded by`feesAvailableForWithdraw` |

## Key Differences from LocalCryptos

| Feature | LocalCryptos (ETH) | LocalUSDT |
|---------|-------------------|-----------|
| Asset | Native ETH | ERC-20 USDT (TRC-20 / BEP-20) |
| Funding |`msg.value` |`transferFrom()` (requires prior approval) |
| Fees | Collected in ETH | Collected in USDT |
| USDT compatibility | N/A | Safe transfer helpers for non-standard USDT on Ethereum |
| Solidity version | 0.4.x / 0.5.x | 0.8.24 (built-in overflow protection) |
| Relay system | ✅ | ✅ (retained — platform pays gas on behalf of users) |

## Contract Architecture

```
LocalUSDTEscrow
├── State
│   ├── usdtToken (immutable)    — USDT contract address for this chain
│   ├── arbitrator               — resolves disputes
│   ├── owner                    — manages settings, withdraws fees
│   ├── inviterAddress           — co-signs escrow creation
│   ├── relayers                 — authorized gas relayers
│   └── escrows                  — mapping(tradeHash => Escrow)
│
├── Core Actions
│   ├── createEscrow()           — fund a new escrow (pulls USDT via transferFrom)
│   ├── release()                — seller releases USDT to buyer
│   ├── buyerCancel()            — buyer cancels, returns USDT to seller
│   ├── sellerCancel()           — seller cancels after payment window
│   ├── sellerRequestCancel()    — seller requests cancel (starts countdown)
│   ├── disableSellerCancel()    — buyer marks payment sent (locks escrow)
│   └── resolveDispute()         — arbitrator resolves dispute
│
├── Relay System
│   ├── relay()                  — execute a signed instruction
│   └── batchRelay()             — batch multiple relay calls
│
├── Owner Functions
│   ├── withdrawFees()           — withdraw collected platform fees only
│   ├── setArbitrator()          — change arbitrator address
│   ├── setOwner()               — transfer ownership
│   ├── setRelayer()             — enable/disable relayer
│   ├── setInviterAddress()      — change invitation signer
│   ├── setRequestCancellationMinimumTime()
│   └── recoverStuckTokens()     — recover accidentally sent tokens
│
└── Helpers (private)
    ├── _safeTransfer()          — handles non-standard USDT
    ├── _safeTransferFrom()      — handles non-standard USDT
    ├── transferMinusFees()      — distribute minus platform + gas fees
    ├── increaseGasSpent()       — track relay gas costs
    ├── getEscrowAndHash()       — compute trade hash, return escrow
    ├── getRelayedSender()       — recover relay signer
    └── recoverAddress()         — ecrecover wrapper
```

## Escrow Lifecycle

```
Seller approves USDT
        │
        ▼
  createEscrow() ← Platform signs invitation
        │
        ▼
  ┌─────────────┐
  │   ESCROWED   │
  └──────┬──────┘
         │
    ┌────┴─────────────────────┐
    │                          │
    ▼                          ▼
disableSellerCancel()    sellerCancel()
  (buyer marks paid)    (payment window expired)
    │                          │
    ▼                          ▼
  ┌─────────┐          ┌──────────┐
  │  LOCKED  │          │ CANCELLED │ → USDT back to seller
  └────┬────┘          └──────────┘
       │
  ┌────┴────────────┐
  │                 │
  ▼                 ▼
release()     resolveDispute()
  │                 │
  ▼                 ▼
┌──────────┐  ┌──────────────┐
│ RELEASED │  │   RESOLVED    │
│ → buyer  │  │ → split to    │
└──────────┘  │   buyer/seller│
              └──────────────┘
```

## USDT Non-Standard Transfer Handling

USDT on Ethereum (`0xdAC17F958D2ee523a2206206994597C13D831ec7`) does **not** return a`bool` from`transfer()` /`transferFrom()`, violating the ERC-20 spec. This contract uses low-level calls with return-data inspection:

```solidity
(bool _success, bytes memory _data) = usdtToken.call(
    abi.encodeWithSignature("transfer(address,uint256)", _to, _value)
);
require(
    _success && (_data.length == 0 || abi.decode(_data, (bool))),
    "USDT transfer failed"
);
```

This safely handles both standard (returns`true`) and non-standard (returns nothing) ERC-20 implementations.

## Fee Structure

| Fee type | When charged | Who pays |
|----------|-------------|----------|
| Platform fee (`_fee`) | On`release()` and`resolveDispute()`| Deducted from escrowed amount |
| Relay gas reimbursement | When relayer submits transactions | Deducted from escrowed amount |
| **No fee** | On`buyerCancel()`| Only relay gas (if any) is deducted |

The`_fee` parameter is in basis points divided by 100: a value of`100` = 1.00%.

## Deployment

The same contract is deployed on each supported chain, configured with that chain's USDT token address:

| Network | USDT Address |
|---------|-------------|
| Ethereum |`0xdAC17F958D2ee523a2206206994597C13D831ec7` |
| BNB Smart Chain |`0x55d398326f99059fF775485246999027B3197955` |
| Tron |`TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t` |

## Build & Test

```bash
# Install dependencies
npm install

# Compile
npx hardhat compile

# Run tests
npx hardhat test

# Deploy (example: BSC testnet)
npx hardhat run scripts/deploy.js --network bscTestnet
```

## License

Apache-2.0

## Links

- **Website:** [localusdt.app](https://localusdt.app)
- **Contract explainer:** [localusdt.app/contracts](https://localusdt.app/contracts)
- **Security:** [localusdt.app/security](https://localusdt.app/security)
- **Help Center:** [localusdt.app/help](https://localusdt.app/help)
