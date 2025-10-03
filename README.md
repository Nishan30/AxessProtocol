# AxessProtocol — Smart Contracts (Aptos / Move)

Programmable, trustless **DeFi for AI compute** on Aptos.
This repo contains the on-chain Move modules that tokenize GPU availability, escrow renter payments, and stream earnings to providers while sessions run off-chain.

This is part of a 4 repo project:

SmartContracts: https://github.com/Nishan30/AxessProtocol

Frontend: https://github.com/Nishan30/AxessProtocolFrontend

Backend: https://github.com/aniJani/AxessProtocolBackend

Oracle Agent: https://github.com/aniJani/oracleAgent

---

## ✨ What's inside

* `marketplace`: host registration, listings, availability, and session lifecycle
* `escrow`: per-job escrow, streaming claims, and final settlement
* `types`: shared structs, events, and helpers
* `tests`: Move unit tests for critical flows

```
.
├─ Move.toml
├─ sources/
│  ├─ marketplace.move
│  ├─ escrow.move
│  ├─ types.move
│  └─ errors.move
└─ tests/
   ├─ marketplace_tests.move
   └─ escrow_tests.move
```

---

## 🧠 High-level architecture

1. **Host listing (provider)**

   * Registers machine specs (GPU model, cores, RAM)
   * Sets `is_available = true/false`
   * Publishes `Listing` under host account

2. **Renter session**

   * Off-chain matcher (backend) creates a **job** with duration and price
   * Renter funds escrow (`APT`/Fungible Asset)
   * Backend signals agent → starts container → returns URL
   * Provider claims streaming payments while job is active

3. **Settlement**

   * Final claim closes escrow
   * Events emitted for analytics & bookkeeping

---

## 📦 Key resources & entry functions

### `marketplace`

* **Resources**

  * `Listing { gpu_model, cpu_cores, ram_gb, price_per_second, is_available, active_job_id }`

* **Entry functions**

  * `register_host_machine(gpu_model: string, cpu_cores: u64, ram_gb: u64, price_per_second: u64, pubkey: vector<u8>)`
  * `set_availability(is_available: bool)`
  * *(optional)* `attach_active_job(job_id: u64)` / `clear_active_job()`

* **Events**

  * `HostRegistered`, `AvailabilitySet`, `JobAttached`, `JobCleared`

### `escrow`

* **Resources**

  * `Job { id, renter, provider, start_time, max_end_time, total_escrow_amount, claimed_amount, is_active }`

* **Entry functions**

  * `fund_and_start_job(provider: address, max_end_time: u64, price_per_second: u64)`
    *moves funds into escrow and flips `is_active`*
  * `claim_payment(job_id: u64, now_ts: u64, final_session_duration: u64)`
    *streaming claim; `final_session_duration` > 0 on the last claim*
  * `cancel_before_start(job_id: u64)` (safety hatch if session never starts)

* **Events**

  * `JobStarted`, `PaymentClaimed`, `JobClosed`, `JobCanceled`

---

## 🛠 Prerequisites

* [Aptos CLI](https://aptos.dev/cli-tools/aptos-cli-tool/install-cli/)
* Rust toolchain (for Move prover/testing)
* Funded testnet account & `.aptos/config.yaml`

---

## 🚀 Build, test, and publish

```bash
# 1) Configure your profile (testnet)
aptos init --profile devnet \
  --network testnet \
  --private-key <YOUR_PRIVATE_KEY_HEX>

# 2) Compile
aptos move compile --named-addresses axess=default

# 3) Unit tests (Move)
aptos move test

# 4) Publish
aptos move publish --profile devnet --named-addresses axess=default
```

> **Named address**: The modules use `axess` as the publishing address in `Move.toml`.
> Replace or map to your account in commands via `--named-addresses axess=0xYOURADDR`.

---

## 🧪 Quick interaction (CLI examples)

```bash
# Register a host
aptos move run --profile devnet \
  --function 0x<axess>::marketplace::register_host_machine \
  --args string:"NVIDIA RTX 4090" u64:16 u64:64 u64:5 hex:"<host_pubkey_bytes>"

# Set availability ON
aptos move run --profile devnet \
  --function 0x<axess>::marketplace::set_availability \
  --args bool:true

# Renter funds & starts a job (example: 2 hours x 5 APT/s -> 36000 APT-octas)
aptos move run --profile devnet \
  --function 0x<axess>::escrow::fund_and_start_job \
  --args address:0x<provider> u64:<max_end_timestamp> u64:5

# Provider claims streaming payment
aptos move run --profile devnet \
  --function 0x<axess>::escrow::claim_payment \
  --args u64:<job_id> u64:<now_ts> u64:0

# Final claim at end (provide final_session_duration)
aptos move run --profile devnet \
  --function 0x<axess>::escrow::claim_payment \
  --args u64:<job_id> u64:<end_ts> u64:<seconds_used>
```

---

## 🔗 Off-chain integration (agent/backend)

* **Agent** opens a WS channel to the backend, starts/stops GPU containers on demand, and periodically calls:

  * `marketplace::set_availability(bool)`
  * `escrow::claim_payment(job_id, now_ts, final_session_duration)`
* **Backend**:

  * Matches renter ↔ provider
  * Ensures renter escrow is funded before instructing agent to start session
  * Tracks `JobStarted`/`PaymentClaimed`/`JobClosed` events for analytics

**Event-driven flow** makes it easy to build explorers, dashboards, and accounting tools.

---

## 🔒 Security notes

* **Escrow is pull-based**: providers only claim what's accrued by `now_ts`.
* **No custody of private keys**: all calls are user-signed via Aptos wallets/CLI.
* **Bounds checks**: `price_per_second`, `max_end_time`, and job ownership are enforced.
* **Reentrancy**: Move's resource model prevents classic reentrancy; we still gate state transitions with explicit flags (`is_active`, `claimed_amount` monotonicity).
* **Upgradability**: keep `struct`/`event` layout compatibility in mind; prefer additive changes.

---

## 💵 Fees & assets

* Default settlement asset: **APT** (octas) via fungible asset store.
* The design supports adding other FA-compatible tokens later (stablecoins, etc.).

---

## 🗺 Roadmap (contracts)

* Vaults for **pooled compute** with tranching & SLAs
* **Reputation & slashing** for uptime and quality guarantees
* **Multi-asset escrow** (stables, bridged assets)
* **Oracle attestations** for session proofs (ZK or signed reports)
* On-chain **auction** price discovery for scarce GPUs

---

## 🧩 Config

* `Move.toml` exposes the `axess` named address.
* Environment variables are not used directly on-chain; off-chain components pass parameters via entry functions.

---


**AxessProtocol** turns GPU time into a first-class, composable asset on Aptos—so any AI/ML product can programmatically *rent, pay, and settle* compute the moment it's needed.
