# AxessProtocol — Smart Contracts (Aptos / Move)

Programmable, trustless **DeFi for AI compute** on Aptos.
This repo contains the on-chain Move modules that tokenize GPU availability, escrow renter payments, and stream earnings to providers while sessions run off-chain.

This is part of a 4 repo project:

- **Smart Contracts**: https://github.com/Nishan30/AxessProtocol
- **Frontend**: https://github.com/Nishan30/AxessProtocolFrontend
- **Backend**: https://github.com/aniJani/AxessProtocolBackend
- **Oracle Agent**: https://github.com/aniJani/oracleAgent

---

## ✨ What's inside

* `marketplace`: host registration, listings, availability, and session lifecycle
* `escrow`: per-job escrow, streaming claims, final settlement, and compute request handling
* `reputation`: tracks host performance metrics (completed jobs, total uptime)
* `tests`: Move integration tests for critical flows

```
.
├─ Move.toml
├─ sources/
│  ├─ marketplace.move
│  ├─ escrow.move
│  └─ reputation.move
└─ tests/
   └─ marketplace_integration_tests.move
```

---

## 🧠 High-level architecture

1. **Host listing (provider)**

   * Registers machine specs (GPU model, CPU cores, RAM)
   * Sets `is_available = true/false`
   * Publishes `Listing` under host account

2. **Renter session (direct rental)**

   * Renter directly calls `rent_machine_direct()` to rent from a specific host
   * Funds are escrowed automatically
   * Provider claims streaming payments while job is active

3. **Programmatic compute requests**

   * Requester submits a compute job with requirements (specs, container image, budget)
   * Escrow holds funds until a qualifying host accepts
   * Host accepts request, starts job, and claims payment incrementally

4. **Reputation tracking**

   * Hosts earn reputation through completed jobs and uptime
   * Reputation data stored on-chain for transparency

5. **Settlement**

   * Final claim closes escrow
   * Events emitted for analytics & bookkeeping

---

## 📦 Key resources & entry functions

### `marketplace`

* **Resources**

  * `Listing { listing_type, price_per_second, is_available, is_rented, active_job_id, host_public_key }`
  * `ListingType` enum: `Physical(PhysicalSpecs)` or `Cloud(CloudDetails)`

* **Entry functions**

  * `register_host_machine(gpu_model: String, cpu_cores: u64, ram_gb: u64, price_per_second: u64, host_public_key: vector<u8>)`
  * `set_availability(is_available: bool)`

* **View functions**

  * `get_listing_view(host_address: address): ListingView` - returns a safe, copyable view of listing data

* **Friend functions** (callable by `escrow` module)

  * `claim_listing_for_rent(host_address: address, job_id: u64): u64`
  * `release_listing_after_rent(host_address: address)`
  * `verify_listing_is_acceptable(host_address: address, max_price_per_second: u64, required_cpu_cores: u64, required_ram_gb: u64)`

### `escrow`

* **Resources**

  * `EscrowVault { jobs, job_funds, open_requests, next_job_id, next_request_id }`
  * `Job { job_id, renter_address, host_address, start_time, max_end_time, total_escrow_amount, claimed_amount, is_active }`
  * `ComputeRequestJob { request_id, requester_address, request_details, escrowed_amount, is_pending }`
  * `RenterJobs { job_ids }` - tracks all jobs for a renter

* **Entry functions**

  * `initialize_vault(sender: &signer)` - must be called once by contract deployer
  * `rent_machine_direct(renter: &signer, host_address: address, duration_seconds: u64)` - direct rental flow
  * `request_compute(requester: &signer, container_image: String, has_input_data_uri: bool, input_data_uri_string: String, min_cpu_cores: u64, min_ram_gb: u64, max_cost_per_second: u64, max_duration_seconds: u64)` - create programmatic compute request
  * `accept_compute_request(host: &signer, request_id: u64)` - host accepts an open request
  * `claim_payment(host: &signer, job_id: u64, claim_timestamp: u64, final_session_duration: u64)` - streaming claims
  * `terminate_job(renter: &signer, job_id: u64)` - early termination with refund

* **View functions**

  * `get_job(job_id: u64): Job`
  * `get_jobs_by_renter(renter_address: address): vector<Job>`

### `reputation`

* **Resources**

  * `ReputationVault { scores }` - global table of host reputations
  * `ReputationScore { completed_jobs, total_uptime_seconds }`

* **Entry functions**

  * `initialize_vault(sender: &signer)` - must be called once by contract deployer

* **View functions**

  * `get_host_reputation(host_address: address): Option<ReputationScore>`

* **Friend functions** (callable by `escrow` module)

  * `record_job_completion(host_address: address, job_duration_seconds: u64)`

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
aptos move compile --named-addresses UnifiedCompute=default

# 3) Unit tests (Move)
aptos move test

# 4) Publish
aptos move publish --profile devnet --named-addresses UnifiedCompute=default --skip-fetch-latest-git-deps

# 5) Initialize vaults (REQUIRED after deployment)
aptos move run --function-id <YOUR_CONTRACT_ADDRESS>::escrow::initialize_vault --profile devnet
aptos move run --function-id <YOUR_CONTRACT_ADDRESS>::reputation::initialize_vault --profile devnet
```

> **Named address**: The modules use `UnifiedCompute` as the publishing address in `Move.toml`.
> Replace or map to your account in commands via `--named-addresses UnifiedCompute=0xYOURADDR`.

**Current deployed address (testnet):**
```
0xc6cb811e72af6ce5036b2d8812536ce2fd6213a403a892a8b6b7154443da19ba
```

---

## 🧪 Quick interaction (CLI examples)

```bash
# Register a host machine
aptos move run --profile devnet \
  --function-id 0xc6cb811e72af6ce5036b2d8812536ce2fd6213a403a892a8b6b7154443da19ba::marketplace::register_host_machine \
  --args string:"NVIDIA RTX 4090" u64:16 u64:64 u64:250 hex:""

# Set availability ON
aptos move run --profile devnet \
  --function-id 0xc6cb811e72af6ce5036b2d8812536ce2fd6213a403a892a8b6b7154443da19ba::marketplace::set_availability \
  --args bool:true

# Direct rental: renter rents from specific host for 100 seconds
aptos move run --profile devnet \
  --function-id 0xc6cb811e72af6ce5036b2d8812536ce2fd6213a403a892a8b6b7154443da19ba::escrow::rent_machine_direct \
  --args address:0x<HOST_ADDRESS> u64:100

# Programmatic compute request
aptos move run --profile devnet \
  --function-id 0xc6cb811e72af6ce5036b2d8812536ce2fd6213a403a892a8b6b7154443da19ba::escrow::request_compute \
  --args string:"pytorch/pytorch:latest" bool:false string:"" u64:8 u64:16 u64:300 u64:1000

# Host accepts compute request
aptos move run --profile devnet \
  --function-id 0xc6cb811e72af6ce5036b2d8812536ce2fd6213a403a892a8b6b7154443da19ba::escrow::accept_compute_request \
  --args u64:0

# Provider claims streaming payment
aptos move run --profile devnet \
  --function-id 0xc6cb811e72af6ce5036b2d8812536ce2fd6213a403a892a8b6b7154443da19ba::escrow::claim_payment \
  --args u64:<JOB_ID> u64:<NOW_TIMESTAMP> u64:0

# Terminate job early (renter)
aptos move run --profile devnet \
  --function-id 0xc6cb811e72af6ce5036b2d8812536ce2fd6213a403a892a8b6b7154443da19ba::escrow::terminate_job \
  --args u64:<JOB_ID>
```

---

## 🔗 Off-chain integration (agent/backend)

* **Agent** opens a WebSocket channel to the backend, starts/stops GPU containers on demand, and periodically calls:

  * `marketplace::set_availability(bool)`
  * `escrow::claim_payment(job_id, now_ts, final_session_duration)`
  
* **Backend**:

  * Matches renter ↔ provider
  * Ensures renter escrow is funded before instructing agent to start session
  * Monitors compute requests and notifies qualified hosts
  * Tracks events for analytics (`JobStarted`, `PaymentClaimed`, `JobClosed`)

**Event-driven flow** makes it easy to build explorers, dashboards, and accounting tools.

---

## 🔒 Security notes

* **Escrow is pull-based**: providers only claim what's accrued by timestamp
* **No custody of private keys**: all calls are user-signed via Aptos wallets/CLI
* **Bounds checks**: `price_per_second`, `max_end_time`, and job ownership are enforced
* **Reentrancy**: Move's resource model prevents classic reentrancy; state transitions are gated with explicit flags (`is_active`, `claimed_amount` monotonicity)
* **Spec verification**: programmatic requests verify hosts meet minimum requirements before acceptance
* **Upgradability**: maintain `struct`/`event` layout compatibility; prefer additive changes

---

## 💵 Fees & assets

* Default settlement asset: **APT** (octas) via `aptos_framework::coin`
* The design supports adding other fungible assets later (stablecoins, etc.)

---

## 🗺 Roadmap (contracts)

* Vaults for **pooled compute** with tranching & SLAs
* **Reputation & slashing** for uptime and quality guarantees (basic reputation tracking implemented)
* **Multi-asset escrow** (stables, bridged assets)
* **Oracle attestations** for session proofs (ZK or signed reports)
* On-chain **auction** price discovery for scarce GPUs
* **Cloud provider integration** (expand `ListingType::Cloud` support)

---

## 🧩 Config

* `Move.toml` exposes the `UnifiedCompute` named address
* Three additional addresses for testing: `HOST_ADDR`, `RENTER_ADDR`, `REQUESTER_ADDR`
* Environment variables are not used directly on-chain; off-chain components pass parameters via entry functions

---


**AxessProtocol** turns GPU time into a first-class, composable asset on Aptos—so any AI/ML product can programmatically *rent, pay, and settle* compute the moment it's needed.
