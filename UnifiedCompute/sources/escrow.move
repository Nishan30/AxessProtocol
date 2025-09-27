module UnifiedCompute::escrow {
    use std::signer;
    use std::string::{String};
    use std::option::{Option};
    use std::vector;

    use aptos_framework::timestamp;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin::{Self as coin, Coin};
    use aptos_std::table::{Self as table, Table};
    use UnifiedCompute::reputation::{Self, ReputationVault};

    // Import the new marketplace model and its structs for validation
    use UnifiedCompute::marketplace::{Self, Listing, ListingType, PhysicalSpecs};

    // --- All Constants ---
    const E_JOB_NOT_FOUND: u64 = 1;
    const E_UNAUTHORIZED: u64 = 2;
    const E_ALREADY_PAID: u64 = 4;
    const E_JOB_INACTIVE: u64 = 5;
    const E_BAD_DURATION: u64 = 6;
    const E_CLAIM_TIME: u64 = 7;
    // --- NEW: Constants for Programmatic Access ---
    const E_REQUEST_NOT_FOUND: u64 = 8;
    const E_INSUFFICIENT_SPECS: u64 = 9;
    const E_PRICE_TOO_HIGH: u64 = 10;
    const E_REQUEST_ALREADY_ACCEPTED: u64 = 11;


    // --- Struct for tracking jobs per-user (from your original file) ---
    struct RenterJobs has key {
        job_ids: vector<u64>,
    }

    // --- NEW: Standardized Structs for Programmatic Compute ---
    struct RequiredSpecs has store, drop, copy {
        min_cpu_cores: u64,
        min_ram_gb: u64,
    }

    struct AptosComputeRequest has store, drop, copy {
        container_image: String,
        input_data_uri: Option<String>,
        required_specs: RequiredSpecs,
        max_cost_per_second: u64,
        max_duration_seconds: u64,
    }

    struct ComputeRequestJob has store, copy, drop {
        request_id: u64,
        requester_address: address,
        request_details: AptosComputeRequest,
        escrowed_amount: u64,
        is_pending: bool,
    }

    // --- UPDATED: EscrowVault now includes the public job queue ---
    struct EscrowVault has key {
        jobs: Table<u64, Job>,
        job_funds: Table<u64, Coin<AptosCoin>>,
        open_requests: Table<u64, ComputeRequestJob>,
        next_job_id: u64,
        next_request_id: u64,
    }

    // --- UPDATED: Job struct no longer needs listing_id ---
    struct Job has store, drop, copy {
        job_id:u64,
        renter_address: address,
        host_address: address,
        start_time: u64,
        max_end_time: u64,
        total_escrow_amount: u64,
        claimed_amount: u64,
        is_active: bool,
    }

    // --- UPDATED: initialize_vault for the new EscrowVault structure ---
    public entry fun initialize_vault(sender: &signer) {
        let sender_addr = signer::address_of(sender);
        assert!(sender_addr == @UnifiedCompute, E_UNAUTHORIZED);
        if (!exists<EscrowVault>(sender_addr)) {
            move_to(sender, EscrowVault {
                jobs: table::new<u64, Job>(),
                job_funds: table::new<u64, Coin<AptosCoin>>(),
                open_requests: table::new<u64, ComputeRequestJob>(),
                next_job_id: 0,
                next_request_id: 0,
            });
        }
    }

    // --- UPDATED: `rent_machine` is now for direct rentals via the UI ---
    // It is adapted for the "one machine, one listing" model.
    public entry fun rent_machine_direct(
        renter: &signer,
        host_address: address,
        duration_seconds: u64
    ) acquires EscrowVault, RenterJobs, marketplace::Listing {
        assert!(duration_seconds > 0, E_BAD_DURATION);

        let vault = borrow_global_mut<EscrowVault>(@UnifiedCompute);
        let renter_address = signer::address_of(renter);
        let new_job_id = vault.next_job_id;
        vault.next_job_id = vault.next_job_id + 1;

        // Call the updated marketplace function, which now takes the job_id.
        let price_per_second = marketplace::claim_listing_for_rent(host_address, new_job_id);
        let total_cost = price_per_second * duration_seconds;
        let escrowed_coins = coin::withdraw<AptosCoin>(renter, total_cost);
        let now = timestamp::now_seconds();

        let new_job = Job {
            job_id: new_job_id,
            renter_address: signer::address_of(renter),
            host_address,
            start_time: now,
            max_end_time: now + duration_seconds,
            total_escrow_amount: total_cost,
            claimed_amount: 0,
            is_active: true,
        };

        table::add(&mut vault.jobs, new_job_id, new_job);
        table::add(&mut vault.job_funds, new_job_id, escrowed_coins);

        // Add the job ID to the renter's personal job list
        if (!exists<RenterJobs>(renter_address)) {
            move_to(renter, RenterJobs { job_ids: vector::empty() });
        };
        let renter_jobs = borrow_global_mut<RenterJobs>(renter_address);
        vector::push_back(&mut renter_jobs.job_ids, new_job_id);
    }

    // --- NEW: Functions for Programmatic Access Protocol ---

    public entry fun request_compute(
        requester: &signer,
        request: AptosComputeRequest
    ) acquires EscrowVault {
        let vault = borrow_global_mut<EscrowVault>(@UnifiedCompute);
        let requester_address = signer::address_of(requester);
        let max_total_cost = request.max_cost_per_second * request.max_duration_seconds;
        assert!(max_total_cost > 0, E_BAD_DURATION);

        let escrowed_coins = coin::withdraw<AptosCoin>(requester, max_total_cost);
        let new_request_id = vault.next_request_id;
        vault.next_request_id = vault.next_request_id + 1;

        let new_request_job = ComputeRequestJob {
            request_id: new_request_id,
            requester_address,
            request_details: request,
            escrowed_amount: max_total_cost,
            is_pending: true,
        };
        table::add(&mut vault.open_requests, new_request_id, new_request_job);
        table::add(&mut vault.job_funds, new_request_id, escrowed_coins);
    }

    public entry fun accept_compute_request(
        host: &signer,
        request_id: u64
    ) acquires EscrowVault, marketplace::Listing {
        let host_address = signer::address_of(host);
        let vault = borrow_global_mut<EscrowVault>(@UnifiedCompute);

        assert!(table::contains(&vault.open_requests, request_id), E_REQUEST_NOT_FOUND);
        let request_job = table::borrow(&vault.open_requests, request_id);
        assert!(request_job.is_pending, E_REQUEST_ALREADY_ACCEPTED);

        let host_listing = marketplace::get_listing(host_address);
        let request_details = &request_job.request_details;

        assert!(host_listing.price_per_second <= request_details.max_cost_per_second, E_PRICE_TOO_HIGH);
        if (let ListingType::Physical(specs) = host_listing.listing_type) {
            assert!(specs.cpu_cores >= request_details.required_specs.min_cpu_cores, E_INSUFFICIENT_SPECS);
            assert!(specs.ram_gb >= request_details.required_specs.min_ram_gb, E_INSUFFICIENT_SPECS);
        } else { abort E_INSUFFICIENT_SPECS };

        let new_job_id = vault.next_job_id;
        vault.next_job_id = vault.next_job_id + 1;

        marketplace::claim_listing_for_rent(host_address, new_job_id);
        let now = timestamp::now_seconds();
        let new_job = Job {
            job_id: new_job_id,
            renter_address: request_job.requester_address,
            host_address,
            start_time: now,
            max_end_time: now + request_details.max_duration_seconds,
            total_escrow_amount: request_job.escrowed_amount,
            claimed_amount: 0,
            is_active: true,
        };
        table::add(&mut vault.jobs, new_job_id, new_job);
        let request_funds = table::remove(&mut vault.job_funds, request_id);
        table::add(&mut vault.job_funds, new_job_id, request_funds);
        table::remove(&mut vault.open_requests, request_id);
    }

    // --- UPDATED: Core Job Lifecycle Functions ---

    public entry fun claim_payment(
        host: &signer,
        job_id: u64,
        claim_timestamp: u64,
        final_session_duration: u64
    ) acquires EscrowVault, marketplace::Listing, ReputationVault {
        let host_address = signer::address_of(host);
        let vault = borrow_global_mut<EscrowVault>(@UnifiedCompute);
        assert!(table::contains(&vault.jobs, job_id), E_JOB_NOT_FOUND);
        let job = table::borrow_mut(&mut vault.jobs, job_id);

        assert!(job.host_address == host_address, E_UNAUTHORIZED);
        assert!(job.is_active, E_JOB_INACTIVE);
        assert!(claim_timestamp >= job.start_time && claim_timestamp <= job.max_end_time, E_CLAIM_TIME);

        let duration = if (job.max_end_time > job.start_time) { job.max_end_time - job.start_time } else { 1 };
        let price_per_second = job.total_escrow_amount / duration;
        let total_due_at_timestamp = (claim_timestamp - job.start_time) * price_per_second;

        if (total_due_at_timestamp > job.total_escrow_amount) {
            total_due_at_timestamp = job.total_escrow_amount;
        };
        assert!(total_due_at_timestamp > job.claimed_amount, E_ALREADY_PAID);
        let payment_to_claim = total_due_at_timestamp - job.claimed_amount;

        let job_coins = table::borrow_mut(&mut vault.job_funds, job_id);
        let payment_coins = coin::extract(job_coins, payment_to_claim);
        coin::deposit(host_address, payment_coins);
        job.claimed_amount = job.claimed_amount + payment_to_claim;

        if (job.claimed_amount >= job.total_escrow_amount || claim_timestamp >= job.max_end_time) {
            job.is_active = false;
            // Call the new marketplace function
            marketplace::release_listing_after_rent(job.host_address);
            reputation::record_job_completion(job.host_address, final_session_duration);
        }
    }

    public entry fun terminate_job(renter: &signer, job_id: u64)
    acquires EscrowVault, marketplace::Listing, ReputationVault {
        let renter_address = signer::address_of(renter);
        let vault = borrow_global_mut<EscrowVault>(@UnifiedCompute);
        assert!(table::contains(&vault.jobs, job_id), E_JOB_NOT_FOUND);
        let job = table::borrow_mut(&mut vault.jobs, job_id);

        assert!(job.renter_address == renter_address, E_UNAUTHORIZED);
        assert!(job.is_active, E_JOB_INACTIVE);

        let remaining_coins = table::remove(&mut vault.job_funds, job_id);
        if (coin::value(&remaining_coins) > 0) {
            coin::deposit(renter_address, remaining_coins);
        } else {
            coin::destroy_zero(remaining_coins);
        };

        let now = timestamp::now_seconds();
        let actual_duration = if (now > job.start_time) { now - job.start_time } else { 0 };
        let max_duration = job.max_end_time - job.start_time;
        if (actual_duration > max_duration) {
            actual_duration = max_duration;
        };

        job.is_active = false;
        // Call the new marketplace function
        marketplace::release_listing_after_rent(job.host_address);
        reputation::record_job_completion(job.host_address, actual_duration);
    }

    // --- VIEW Functions ---

    #[view]
    public fun get_job(job_id: u64): Job acquires EscrowVault {
        let vault = borrow_global<EscrowVault>(@UnifiedCompute);
        assert!(table::contains(&vault.jobs, job_id), E_JOB_NOT_FOUND);
        *table::borrow(&vault.jobs, job_id)
    }

    #[view]
    public fun get_jobs_by_renter(renter_address: address): vector<Job> acquires EscrowVault, RenterJobs {
        if (!exists<RenterJobs>(renter_address)) { return vector::empty() };
        let renter_jobs = borrow_global<RenterJobs>(renter_address);
        let vault = borrow_global<EscrowVault>(@UnifiedCompute);
        let out = vector::empty<Job>();
        let i = 0;
        while (i < vector::length(&renter_jobs.job_ids)) {
            let job_id = *vector::borrow(&renter_jobs.job_ids, i);
            if (table::contains(&vault.jobs, job_id)) {
                let job = *table::borrow(&vault.jobs, job_id);
                vector::push_back(&mut out, job);
            };
            i = i + 1;
        };
        out
    }
}