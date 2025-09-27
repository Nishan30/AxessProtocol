#[test_only]
module UnifiedCompute::integration_tests {
    use std::signer;
    use std::string::{utf8, String};
    use std::option;
    use std::vector;

    use aptos_framework::genesis;
    use aptos_framework::account;
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_framework::coin;

    // Import all the modules from your project
    use UnifiedCompute::marketplace::{Self, Listing};
    use UnifiedCompute::escrow::{Self, AptosComputeRequest, RequiredSpecs};
    use UnifiedCompute::reputation::{Self};

    // --- Test constants ---
    const HOST_ADDR: address = @0x100;
    const RENTER_ADDR: address = @0x200; // For direct rentals
    const REQUESTER_ADDR: address = @0x300; // For programmatic requests
    const INITIAL_BALANCE: u64 = 1_000_000_000;

    // Setup function to initialize the test environment with funded accounts
    fun setup() {
        genesis::setup();
        account::create_account_for_test(HOST_ADDR);
        account::create_account_for_test(RENTER_ADDR);
        account::create_account_for_test(REQUESTER_ADDR);
        
        let framework_signer = account::create_signer_for_test(@aptos_framework);
        aptos_coin::mint(&framework_signer, HOST_ADDR, INITIAL_BALANCE);
        aptos_coin::mint(&framework_signer, RENTER_ADDR, INITIAL_BALANCE);
        aptos_coin::mint(&framework_signer, REQUESTER_ADDR, INITIAL_BALANCE);
    }

    // --- TEST 1: HOST REGISTRATION AND AVAILABILITY ---
    #[test(host = @0x100)]
    fun test_registration_and_availability_toggle(host: &signer) {
        setup();
        // Initialize contracts
        let contract_signer = account::create_signer_for_test(@UnifiedCompute);
        escrow::initialize_vault(&contract_signer);
        reputation::initialize_vault(&contract_signer);

        // 1. Register the machine
        marketplace::register_host_machine(host, utf8(b"RTX 4090"), 16, 24, 250, vector::empty());
        let listing1 = marketplace::get_listing(HOST_ADDR);
        assert!(!listing1.is_available, 1); // Should start as unavailable
        assert!(!listing1.is_rented, 2);

        // 2. Host agent comes online
        marketplace::set_availability(host, true);
        let listing2 = marketplace::get_listing(HOST_ADDR);
        assert!(listing2.is_available, 3);

        // 3. Host agent goes offline
        marketplace::set_availability(host, false);
        let listing3 = marketplace::get_listing(HOST_ADDR);
        assert!(!listing3.is_available, 4);
    }

    // --- TEST 2: FAILS TO REGISTER THE SAME MACHINE TWICE ---
    #[test(host = @0x100)]
    #[expected_failure(abort_code = 5, location = UnifiedCompute::marketplace)]
    fun test_fails_to_register_twice(host: &signer) {
        setup();
        marketplace::register_host_machine(host, utf8(b"RTX 4090"), 16, 24, 250, vector::empty());
        // This second call must fail with E_ONLY_ONE_LISTING_ALLOWED (5)
        marketplace::register_host_machine(host, utf8(b"RTX 3080"), 12, 12, 150, vector::empty());
    }

    // --- TEST 3: FULL DIRECT RENTAL FLOW (UI-DRIVEN) ---
    #[test(host = @0x100, renter = @0x200)]
    fun test_direct_rental_flow_success(host: &signer, renter: &signer) {
        setup();
        let contract_signer = account::create_signer_for_test(@UnifiedCompute);
        escrow::initialize_vault(&contract_signer);
        reputation::initialize_vault(&contract_signer);

        let price = 250;
        let duration = 100;
        let total_cost = (price * duration) as u64;

        // 1. Host registers and comes online
        marketplace::register_host_machine(host, utf8(b"RTX 4090"), 16, 24, price, vector::empty());
        marketplace::set_availability(host, true);
        
        // 2. Renter rents the machine
        escrow::rent_machine_direct(renter, HOST_ADDR, duration);

        // 3. Check states and balances
        let listing = marketplace::get_listing(HOST_ADDR);
        assert!(listing.is_rented, 1);
        assert!(!listing.is_available, 2);
        
        let renter_balance_after = coin::balance<AptosCoin>(RENTER_ADDR);
        assert!(renter_balance_after == INITIAL_BALANCE - total_cost, 3);
        
        // Let's assume the job is terminated by the renter immediately
        escrow::terminate_job(renter, *option::borrow(&listing.active_job_id));

        let listing_after_termination = marketplace::get_listing(HOST_ADDR);
        assert!(!listing_after_termination.is_rented, 4);
        assert!(!listing_after_termination.is_available, 5); // Must be manually brought back online
    }
    
    // --- TEST 4: FULL PROGRAMMATIC FLOW (SMART CONTRACT-DRIVEN) ---
    #[test(host = @0x100, requester = @0x300)]
    fun test_full_programmatic_flow_success(host: &signer, requester: &signer) {
        setup();
        let contract_signer = account::create_signer_for_test(@UnifiedCompute);
        escrow::initialize_vault(&contract_signer);
        reputation::initialize_vault(&contract_signer);

        // 1. Host registers and comes online
        marketplace::register_host_machine(host, utf8(b"RTX 4090"), 16, 24, 250, vector::empty());
        marketplace::set_availability(host, true);

        // 2. Requester (another smart contract or dApp) submits a compute job
        let request = AptosComputeRequest {
            container_image: utf8(b"pytorch/pytorch:latest"),
            input_data_uri: option::none(),
            required_specs: RequiredSpecs { min_cpu_cores: 8, min_ram_gb: 16 },
            max_cost_per_second: 300,
            max_duration_seconds: 1000,
        };
        escrow::request_compute(requester, request);

        // 3. Host's oracle finds the job and accepts it
        let request_id = 0; // The first request will have ID 0
        escrow::accept_compute_request(host, request_id);

        // 4. Verify the job is active and the listing state is correct
        let listing = marketplace::get_listing(HOST_ADDR);
        assert!(listing.is_rented, 1);
        assert!(!listing.is_available, 2);

        let job_id = *option::borrow(&listing.active_job_id);
        let job = escrow::get_job(job_id);
        assert!(job.renter_address == REQUESTER_ADDR, 3);
        assert!(job.host_address == HOST_ADDR, 4);
    }

    // --- TEST 5: FAILS IF HOST SPECS ARE TOO LOW FOR PROGRAMMATIC JOB ---
    #[test(host = @0x100, requester = @0x300)]
    #[expected_failure(abort_code = 9, location = UnifiedCompute::escrow)]
    fun test_fails_to_accept_if_specs_are_too_low(host: &signer, requester: &signer) {
        setup();
        let contract_signer = account::create_signer_for_test(@UnifiedCompute);
        escrow::initialize_vault(&contract_signer);

        // Host registers a mid-tier machine (12GB RAM)
        marketplace::register_host_machine(host, utf8(b"RTX 3080"), 12, 12, 150, vector::empty());
        marketplace::set_availability(host, true);

        // Requester submits a job that needs a high-end machine (16GB RAM)
        let request = AptosComputeRequest {
            container_image: utf8(b"tensorflow/tensorflow:latest"),
            input_data_uri: option::none(),
            required_specs: RequiredSpecs { min_cpu_cores: 8, min_ram_gb: 16 }, // Requires more RAM than host has
            max_cost_per_second: 200,
            max_duration_seconds: 1000,
        };
        escrow::request_compute(requester, request);

        // Host tries to accept the job. This MUST fail with E_INSUFFICIENT_SPECS (9)
        escrow::accept_compute_request(host, 0);
    }
}