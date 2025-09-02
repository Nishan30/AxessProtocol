#[test_only]
module UnifiedCompute::marketplace_integration_tests {
    use std::string::utf8;
    use std::vector;
    use UnifiedCompute::marketplace::{Self};
    use UnifiedCompute::escrow;

    // --- NEW, CRITICAL IMPORT ---
    use aptos_framework::genesis;

    use aptos_framework::account;
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_framework::coin;

    const HOST_ADDR: address = @0x100;
    const RENTER_ADDR: address = @0x200;
    const ANOTHER_RENTER_ADDR: address = @0x300;
    const HOST_INITIAL_BALANCE: u64 = 1_000_000;
    const RENTER_INITIAL_BALANCE: u64 = 1_000_000_000;

    // This setup function is now 100% correct for the modern test environment.
    fun setup() {
        // --- THE FINAL FIX ---
        // 1. Initialize the entire test blockchain state. This MUST be the first call.
        //    It correctly sets up AptosCoin and gives @aptos_framework minting rights.
        genesis::setup();

        // 2. Create the accounts we will use for the test.
        account::create_account_for_test(HOST_ADDR);
        account::create_account_for_test(RENTER_ADDR);
        
        // 3. Get a signer for the framework account, which now has minting power.
        let framework_signer = account::create_signer_for_test(@aptos_framework);

        // 4. Mint funds. This will now succeed.
        aptos_coin::mint(&framework_signer, HOST_ADDR, HOST_INITIAL_BALANCE);
        aptos_coin::mint(&framework_signer, RENTER_ADDR, RENTER_INITIAL_BALANCE);
    }

    #[test(host = @0x100, renter = @0x200)]
    fun test_direct_pay_rental_flow(host: &signer, renter: &signer) {
        setup();

        let price = 250;
        let duration = 600;
        let total_cost = (price * duration) as u64;

        marketplace::list_machine(host, true, utf8(b"GPU 1"), price);
        escrow::rent_machine(renter, HOST_ADDR, 0, duration);

        let listing_after = marketplace::get_listing_by_id(HOST_ADDR, 0);
        assert!(marketplace::is_available(&listing_after) == false, 1);
        
        let renter_balance_after = coin::balance<AptosCoin>(RENTER_ADDR);
        let host_balance_after = coin::balance<AptosCoin>(HOST_ADDR);

        assert!(renter_balance_after < RENTER_INITIAL_BALANCE, 2);
        assert!(host_balance_after == HOST_INITIAL_BALANCE + total_cost, 3);
    }

    #[test(host = @0x100)]
    fun test_host_can_list_multiple_machines(host: &signer) {
        // This test doesn't need funds, so it can just create an account.
        account::create_account_for_test(HOST_ADDR);
        marketplace::list_machine(host, true, utf8(b"NVIDIA RTX 4090"), 250);
        marketplace::list_machine(host, true, utf8(b"NVIDIA RTX 3080"), 150);
        let listings = marketplace::get_listings_by_host(HOST_ADDR);
        assert!(vector::length(&listings) == 2, 1);
    }

    #[test(
        host = @0x100,
        renter = @0x200,
        another_renter = @0x300
    )]
    #[expected_failure(abort_code = 3, location = UnifiedCompute::marketplace)]
    fun test_cannot_rent_an_unavailable_machine(host: &signer, renter: &signer, another_renter: &signer) {
        setup();
        
        // We also need to fund the 'another_renter' account
        account::create_account_for_test(ANOTHER_RENTER_ADDR);
        let framework_signer = account::create_signer_for_test(@aptos_framework);
        aptos_coin::mint(&framework_signer, ANOTHER_RENTER_ADDR, RENTER_INITIAL_BALANCE);

        marketplace::list_machine(host, true, utf8(b"NVIDIA RTX 4090"), 250);
        
        escrow::rent_machine(another_renter, HOST_ADDR, 0, 600);
        escrow::rent_machine(renter, HOST_ADDR, 0, 600);
    }
}