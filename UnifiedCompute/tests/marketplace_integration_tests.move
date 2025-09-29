#[test_only]
module UnifiedCompute::integration_tests {
    use std::string::{utf8};
    use std::vector;
    use std::signer;

    // This is the correct set of imports for modern testing
    use aptos_framework::account;
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_framework::coin;

    use UnifiedCompute::marketplace;
    use UnifiedCompute::escrow;
    use UnifiedCompute::reputation;

    const INITIAL_BALANCE: u64 = 100_000_000_000;

    /// Helper to initialize and fund accounts.
    fun setup_and_fund(
    contract_signer: &signer,
    host: &signer,
    renter: &signer,
    requester: &signer,
    fund_renter: bool,
    fund_requester: bool,
    ) {
        // Register CoinStores for each participant
        coin::register<AptosCoin>(host);
        coin::register<AptosCoin>(renter);
        coin::register<AptosCoin>(requester);

        escrow::initialize_vault(contract_signer);
        reputation::initialize_vault(contract_signer);

        let framework_signer = account::create_signer_for_test(@aptos_framework);

        // Register CoinStore for framework_signer if needed
        coin::register<AptosCoin>(&framework_signer);

        // Mint initial balance to framework_signer if needed
        // (If you have access to mint capability in test context. Otherwise, framework_signer may already have funds.)

        coin::transfer<AptosCoin>(&framework_signer, signer::address_of(host), INITIAL_BALANCE);

        if (fund_renter) {
            coin::transfer<AptosCoin>(&framework_signer, signer::address_of(renter), INITIAL_BALANCE);
        };

        if (fund_requester) {
            coin::transfer<AptosCoin>(&framework_signer, signer::address_of(requester), INITIAL_BALANCE);
        };
    }

    #[test(host = @0x100, contract_signer = @UnifiedCompute)]
    public fun test_registration_and_availability_toggle(host: &signer, contract_signer: &signer) {
        // We pass dummy signers for unused roles
        setup_and_fund(contract_signer, host, host, host, false, false);

        marketplace::register_host_machine(host, utf8(b"RTX 4090"), 16, 24, 250, vector::empty());
        
        let view1 = marketplace::get_listing_view(@0x100);
        assert!(!marketplace::view_is_available(&view1), 1);
        assert!(!marketplace::view_is_rented(&view1), 2);

        marketplace::set_availability(host, true);
        let view2 = marketplace::get_listing_view(@0x100);
        assert!(marketplace::view_is_available(&view2), 3);

        marketplace::set_availability(host, false);
        let view3 = marketplace::get_listing_view(@0x100);
        assert!(!marketplace::view_is_available(&view3), 4);
    }

    #[test(host = @0x100)]
    #[expected_failure(abort_code = 5, location = UnifiedCompute::marketplace)]
    public fun test_fails_to_register_twice(host: &signer) {
        marketplace::register_host_machine(host, utf8(b"RTX 4090"), 16, 24, 250, vector::empty());
        marketplace::register_host_machine(host, utf8(b"RTX 3080"), 12, 12, 150, vector::empty());
    }

    #[test(host = @0x100, renter = @0x200, contract_signer = @UnifiedCompute)]
    public fun test_direct_rental_flow_success(host: &signer, renter: &signer, contract_signer: &signer) {
        // Pass a dummy for the unused requester role
        setup_and_fund(contract_signer, host, renter, renter, true, false);

        let price = 250;
        let duration = 100;
        let total_cost = (price * duration) as u64;
        let host_addr = signer::address_of(host);
        let renter_addr = signer::address_of(renter);

        marketplace::register_host_machine(host, utf8(b"RTX 4090"), 16, 24, price, vector::empty());
        marketplace::set_availability(host, true);
        
        escrow::rent_machine_direct(renter, host_addr, duration);

        let view = marketplace::get_listing_view(host_addr);
        assert!(marketplace::view_is_rented(&view), 1);
        assert!(!marketplace::view_is_available(&view), 2);
        
        let renter_balance_after = coin::balance<AptosCoin>(renter_addr);
        assert!(renter_balance_after == INITIAL_BALANCE - total_cost, 3);
        
        escrow::terminate_job(renter, *std::option::borrow(marketplace::view_active_job_id(&view)));

        let view_after_termination = marketplace::get_listing_view(host_addr);
        assert!(!marketplace::view_is_rented(&view_after_termination), 4);
        assert!(!marketplace::view_is_available(&view_after_termination), 5);
    }
    
    #[test(host = @0x100, requester = @0x300, contract_signer = @UnifiedCompute)]
    public fun test_full_programmatic_flow_success(host: &signer, requester: &signer, contract_signer: &signer) {
        // Pass a dummy for the unused renter role
        setup_and_fund(contract_signer, host, requester, requester, false, true);

        let host_addr = signer::address_of(host);
        let requester_addr = signer::address_of(requester);

        marketplace::register_host_machine(host, utf8(b"RTX 4090"), 16, 24, 250, vector::empty());
        marketplace::set_availability(host, true);

        escrow::request_compute(
            requester,
            utf8(b"pytorch/pytorch:latest"),
            false, utf8(b""),
            8, 16, 300, 1000
        );

        let request_id = 0;
        escrow::accept_compute_request(host, request_id);

        let view = marketplace::get_listing_view(host_addr);
        assert!(marketplace::view_is_rented(&view), 1);
        assert!(!marketplace::view_is_available(&view), 2);

        let job_id = *std::option::borrow(marketplace::view_active_job_id(&view));
        let job = escrow::get_job(job_id);
        assert!(escrow::renter_address(&job) == requester_addr, 3);
        assert!(escrow::host_address(&job) == host_addr, 4);
    }

    #[test(host = @0x100, requester = @0x300, contract_signer = @UnifiedCompute)]
    #[expected_failure(abort_code = 7, location = UnifiedCompute::marketplace)]
    public fun test_fails_to_accept_if_specs_are_too_low(host: &signer, requester: &signer, contract_signer: &signer) {
        setup_and_fund(contract_signer, host, requester, requester, false, true);

        marketplace::register_host_machine(host, utf8(b"RTX 3080"), 12, 12, 150, vector::empty());
        marketplace::set_availability(host, true);

        escrow::request_compute(
            requester,
            utf8(b"tensorflow/tensorflow:latest"),
            false, utf8(b""),
            8, 16, 200, 1000
        );
        
        escrow::accept_compute_request(host, 0);
    }
}