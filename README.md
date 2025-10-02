# Lido Withdrawal Anomaly Trap — README

A compact, practical README that explains what the trap does, why it’s useful, how to use it with Drosera, how to test it locally (cast / Foundry / ethers.js examples), and notes on the response contract and configuration.

---

## Table of contents

* Overview
* Key features
* High-level architecture
* When/why to use this trap
* Contracts included
* Deployment & Drosera integration
* Example `drosera.toml`
* Testing / quick start

  * 1. Build & deploy
  * 2. Test `collect()` locally
  * 3. Test `shouldRespond()` (single-sample and multi-sample)
  * 4. Trigger response handler
* Security & operational notes
* Next steps / enhancements
* License

---

## Overview

**Lido Withdrawal Anomaly Trap** monitors the Lido withdrawal queue and associated metrics (queue length, total queued ether, individual user queued shares, stETH supply) and uses a compact risk-scoring heuristic to decide whether an anomaly exists. The trap is written to be Drosera-compatible (view-only `collect()` and a `shouldRespond(bytes[] calldata)` pre-check). A companion on-chain response handler logs incident reports and can simulate operator actions.

This trap is a PoC tailored for the Hoodi test environment (addresses in the contract), but the design & detection logic generalizes to mainnet with the appropriate addresses and production data sources.

---

## Key features

* Multi-metric risk score (queue length, user concentration, impact)
* Fast single-sample reaction path (for urgent anomalies)
* Two-sample and multi-sample trend detection (for more conservative responses)
* Drosera-compatible `collect()` and `shouldRespond()` signatures
* Companion `LidoAnomalyResponseHandler` that records incidents and emits events attributing the reporter (`msg.sender`)
* Example `drosera.toml` snippet included for integration

---

## High-level architecture

1. **Trap (LidoWithdrawalAnomalyTrap.sol)** — view-only `collect()` encodes a `WithdrawalAnomalyData` struct; `shouldRespond()` inspects one or more prior `collect()` outputs (passed by Drosera relay) and decides whether to trigger a response.
2. **Response contract (LidoAnomalyResponseHandler.sol)** — receives the response from Drosera (via `handleWithdrawalAnomaly(string,bytes)`), decodes the encoded `WithdrawalAnomalyData`, stores an incident record, and emits events. It attributes the report to `msg.sender` (the operator / relay).
3. **Drosera Relay** — collects samples (per `block_sample_size`), calls `shouldRespond(bytes[])`. If `true`, Drosera calls your configured `response_contract` / `response_function` to take the on-chain action (or emit the report).

---

## When / why to use this trap

* You want early detection of a coordinated or unusually large exit from Lido (mass withdrawals / stash consolidation).
* You want to monitor for whale behavior (one user queuing a large share of the queue).
* You want a lightweight, on-chain-ready PoC that Drosera operators can run on testnets and adapt for mainnet.

---

## Contracts included

* **LidoWithdrawalAnomalyTrap.sol** — main trap implementing `ITrap` with `collect()` and an adaptive `shouldRespond()` (accepts 1, 2, or 3+ samples).
* **LidoAnomalyResponseHandler.sol** — response contract that stores incident reports and emits events; records reporter (`msg.sender`).

(Addresses inside PoC contracts point to Hoodi test proxies — replace with the real addresses for production.)

---

## Deployment & Drosera integration

1. Compile both contracts with Foundry / Remix / Hardhat.
2. Deploy the trap (`LidoWithdrawalAnomalyTrap`) to the target chain.
3. Deploy the response handler (`LidoAnomalyResponseHandler`) and note its address.
4. Update `drosera.toml` (example below) to point `response_contract` to the deployed response handler and set `block_sample_size` to your desired sample window.

### Example `drosera.toml` (single-sample / AVS-like immediate reaction)

```toml
ethereum_rpc = "https://ethereum-hoodi-rpc.publicnode.com"
drosera_rpc = "https://relay.hoodi.drosera.io"
eth_chain_id = 560048
drosera_address = "0x91cB447BaFc6e0EA0F4Fe056F5a9b1F14bb06e5D"

[traps]

[traps.lido_withdrawal_anomaly]
path = "out/LidoWithdrawalAnomalyTrap.sol/LidoWithdrawalAnomalyTrap.json"
response_contract = "0xYourResponseAddress"          # replace with LidoAnomalyResponseHandler address
response_function = "handleWithdrawalAnomaly(string,bytes)"
cooldown_period_blocks = 30
min_number_of_operators = 1
max_number_of_operators = 2
block_sample_size = 1               # use 1 for immediate single-sample checks
private_trap = true
whitelist = ["YOUR_OPERATOR_ADDRESS"]
```

If you prefer time-series detection keep `block_sample_size = 3` (or `10`) and the trap will run its 3+ sample logic.

---

## Testing / quick start

Below are runnable examples and guidance to test the trap + response handler locally. Replace placeholder addresses (`<TRAP_ADDRESS>`, `<RESPONSE_ADDRESS>`) with the deployed contract addresses. The examples use `cast` where possible and a small `ethers.js` snippet for robust calling.

> **Important**: the trap encodes/decodes a `WithdrawalAnomalyData` struct with fields in this order:
>
> ```
> (uint256 queueLength,
>  uint256 totalQueuedShares,
>  uint256 totalQueuedEther,
>  uint256 userShares,
>  uint256 totalStETHSupply,
>  uint256 velocityDelta,
>  uint8   riskLevel,          // enum -> uint8
>  uint256 riskScore,
>  uint256 timestamp,
>  bool    isUserAnomalous)
> ```

### Build & deploy

Use your usual tooling:

* Foundry: `forge build` then `forge create` or `cast send` with private key
* Hardhat / Remix: compile & deploy

---

### 1) Test `collect()` (read-only)

After deploying the trap:

```bash
# Read encoded collect bytes
cast call <TRAP_ADDRESS> "collect()" --rpc-url <RPC>
# If you want to decode the returned bytes offline:
cast abi-decode "(uint256,uint256,uint256,uint256,uint256,uint256,uint8,uint256,uint256,bool)" <HEX_FROM_COLLECT>
```

This returns the `WithdrawalAnomalyData`. You can confirm the trap sees queue size, totalQueuedEther, userShares, etc.

---

### 2) Test `shouldRespond()` — single-sample (cast example)

Below is an example flow that encodes a single `WithdrawalAnomalyData`, and then calls `shouldRespond(bytes[])` with a single-element array. Numbers here are example values that should trigger the trap (e.g., queueLength 1200 > threshold 1000; riskScore 80 -> CRITICAL).

> NOTE: different `cast` versions have subtle differences in how they encode `bytes[]`. If you run into trouble, use the `ethers.js` example further down. The cast examples are concept-level and often work in practice with modern `cast`.

```bash
# Example values (replace timestamp with current epoch seconds)
QUEUE_LEN=1200
TOTAL_SHARES=5
TOTAL_ETHER=100000000000000000000  # 100 ETH (wei)
USER_SHARES=600000000000000000000  # 600 ETH in wei -> above user threshold of 500*1e18
TOTAL_STETH_SUPPLY=1000000000000000000000000
VELOCITY=0
RISK_LEVEL=3   # 0=LOW,1=MEDIUM,2=HIGH,3=CRITICAL
RISK_SCORE=85
TIMESTAMP=1699999999
IS_USER_ANOMALOUS=1  # true

# Build the encoded struct (this produces raw bytes)
COLLECT_HEX=$(cast abi-encode \
  "(uint256,uint256,uint256,uint256,uint256,uint256,uint8,uint256,uint256,bool)" \
  $QUEUE_LEN $TOTAL_SHARES $TOTAL_ETHER $USER_SHARES $TOTAL_STETH_SUPPLY $VELOCITY $RISK_LEVEL $RISK_SCORE $TIMESTAMP $IS_USER_ANOMALOUS)

# Now encode that single bytes element into a bytes[] param (some cast versions accept this)
ARRAY_HEX=$(cast abi-encode "bytes[]" $COLLECT_HEX)

# Call shouldRespond
cast call <TRAP_ADDRESS> "shouldRespond(bytes[])" $ARRAY_HEX --rpc-url <RPC>

# If the trap determines an anomaly, the call returns (true, abi.encode(MESSAGE, abi.encode(latest)))
```

If this path is confusing in your environment, use the Node/ethers example below which is more explicit.

---

### 3) Test `shouldRespond()` — multi-sample (3-sample trend)

To simulate a 3-sample time-series where risk is increasing over time:

* Create three encoded collects: `c0` (latest), `c1`, `c2` (oldest). Use increasing `riskScore` or `queueLength` so the `consecutiveIncrease` logic triggers.

You then call `shouldRespond(bytes[])` with the array `[c0, c1, c2]` and expect `(true, payload)` if the trend triggers.

(You can do this with `cast` similarly to the single-sample example by encoding three entries into `bytes[]`.)

---

### 4) Trigger response handler (simulate Drosera response)

If `shouldRespond()` returned `true`, Drosera will call your configured response function:

```bash
# Example call that an operator/relay would perform:
# response_function = "handleWithdrawalAnomaly(string,bytes)"
# message is a human-readable string; payload is the same bytes produced by collect()

MESSAGE="Lido withdrawal anomaly detected - immediate attention"
# Suppose COLLECT_HEX is the previously generated collect struct
cast send <RESPONSE_CONTRACT_ADDRESS> "handleWithdrawalAnomaly(string,bytes)" "$MESSAGE" $COLLECT_HEX --private-key <OPERATOR_KEY> --rpc-url <RPC>
```

After the call:

* `LidoAnomalyResponseHandler` emits `AnomalyAlert` and `ReportStored`
* The report is recorded with `report.reporter = msg.sender`, making it auditable who caused the report.

---

## Security & operational notes

* **Storage growth**: `LidoAnomalyResponseHandler` appends reports on every response. Consider an off-chain indexer, retention policy, or roll-up mechanism for production.
* **Authority & whitelists**: `drosera.toml` `whitelist` and `min_number_of_operators` control which relays/operators can trigger the response and how many must agree. Tune per risk tolerance.
* **False positives**: Single-sample urgent triggers can cause false positives. If false positives are costly, prefer `block_sample_size = 3` and rely on time-series checks first.
* **Testing on mainnet**: Replace Hoodi addresses with mainnet Lido contracts and thoroughly test `getWithdrawalQueue()` semantics (the PoC treated `timestamps.length` as `totalQueuedShares`; mainnet likely requires iterating struct entries).
* **Event attribution**: The response handler records `msg.sender` as the reporter so you can trace back to the relay/operator EOA or multisig.
* **Gas costs**: `collect()` is `view` and cheap; `handleWithdrawalAnomaly()` is a write and costs gas — plan operator budgets accordingly.

---

## License

MIT — feel free to reuse and adapt this PoC. If you incorporate it into production, please harden, review, and audit.

---


Which of those do you want next?
