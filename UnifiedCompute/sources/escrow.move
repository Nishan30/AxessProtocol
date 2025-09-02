module UnifiedCompute::escrow {
    use std::signer;
    use std::bcs;
    use std::vector;

    use aptos_framework::timestamp;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin::{Self as coin, Coin};
    use aptos_std::table::{Self as table, Table};

    // ✅ Correct ed25519 path + types used by Aptos stdlib
    use aptos_std::ed25519::{Self as ed25519, Signature, UnvalidatedPublicKey};

    use UnifiedCompute::marketplace;

    const E_JOB_NOT_FOUND: u64 = 1;
    const E_UNAUTHORIZED: u64 = 2;
    const E_INVALID_SIGNATURE: u64 = 3;
    const E_ALREADY_PAID: u64 = 4;
    const E_JOB_INACTIVE: u64 = 5;
    const E_BAD_DURATION: u64 = 6;
    const E_CLAIM_TIME: u64 = 7;

    struct EscrowVault has key {
        jobs: Table<u64, Job>,
        job_funds: Table<u64, Coin<AptosCoin>>,
        next_job_id: u64,
    }

    struct Job has store, drop {
        renter_address: address,
        host_address: address,
        listing_id: u64,
        start_time: u64,
        max_end_time: u64,
        total_escrow_amount: u64,
        claimed_amount: u64,
        is_active: bool,
    }

    public entry fun initialize_vault(sender: &signer) {
        let sender_addr = signer::address_of(sender);
        assert!(sender_addr == @UnifiedCompute, E_UNAUTHORIZED);
        if (!exists<EscrowVault>(sender_addr)) {
            move_to(sender, EscrowVault {
                // ✅ Explicit type params for tables
                jobs: table::new<u64, Job>(),
                job_funds: table::new<u64, Coin<AptosCoin>>(),
                next_job_id: 0,
            });
        }
    }

    public entry fun rent_machine(
        renter: &signer,
        host_address: address,
        listing_id: u64,
        duration_seconds: u64
    ) acquires EscrowVault {
        assert!(duration_seconds > 0, E_BAD_DURATION);

        let vault = borrow_global_mut<EscrowVault>(@UnifiedCompute);

        let new_job_id = vault.next_job_id;
        vault.next_job_id = vault.next_job_id + 1;

        // Host moves listing into "claimed" for this job and returns price per second
        let price_per_second = marketplace::claim_listing_for_rent(host_address, listing_id, new_job_id);

        // Simple u64 math (caller should ensure no overflow by reasonable pricing)
        let total_cost = price_per_second * duration_seconds;

        // Take funds from renter
        let escrowed_coins = coin::withdraw<AptosCoin>(renter, total_cost);

        let now = timestamp::now_seconds();
        let new_job = Job {
            renter_address: signer::address_of(renter),
            host_address,
            listing_id,
            start_time: now,
            max_end_time: now + duration_seconds,
            total_escrow_amount: total_cost,
            claimed_amount: 0,
            is_active: true,
        };

        // Record job + store coins
        table::add<u64, Job>(&mut vault.jobs, new_job_id, new_job);
        table::add<u64, Coin<AptosCoin>>(&mut vault.job_funds, new_job_id, escrowed_coins);
    }

    public entry fun claim_payment(
        host: &signer,
        job_id: u64,
        claim_timestamp: u64,
    ) acquires EscrowVault {
        let host_address = signer::address_of(host);
        let vault = borrow_global_mut<EscrowVault>(@UnifiedCompute);

        // Ensure the job exists
        assert!(table::contains<u64, Job>(&vault.jobs, job_id), E_JOB_NOT_FOUND);

        // Borrow the job
        let job = table::borrow_mut<u64, Job>(&mut vault.jobs, job_id);

        // Only the host can claim
        assert!(job.host_address == host_address, E_UNAUTHORIZED);

        // Job must be active
        assert!(job.is_active, E_JOB_INACTIVE);

        // Claim timestamp must be within job duration
        assert!(claim_timestamp >= job.start_time && claim_timestamp <= job.max_end_time, E_CLAIM_TIME);

        // Calculate linear release
        let duration = job.max_end_time - job.start_time;
        let price_per_second = job.total_escrow_amount / duration;

        // Total due at this timestamp
        let total_due_at_timestamp = (claim_timestamp - job.start_time) * price_per_second;
        if (total_due_at_timestamp > job.total_escrow_amount) {
            total_due_at_timestamp = job.total_escrow_amount;
        };

        // Ensure there is something to claim
        assert!(total_due_at_timestamp > job.claimed_amount, E_ALREADY_PAID);

        let payment_to_claim = total_due_at_timestamp - job.claimed_amount;

        // Extract coins from escrow vault
        let job_coins = table::borrow_mut<u64, Coin<AptosCoin>>(&mut vault.job_funds, job_id);
        let payment_coins = coin::extract<AptosCoin>(job_coins, payment_to_claim);

        // Deposit coins to host
        coin::deposit<AptosCoin>(host_address, payment_coins);

        // Update claimed amount
        job.claimed_amount = job.claimed_amount + payment_to_claim;
    }


    public entry fun terminate_job(renter: &signer, job_id: u64)
    acquires EscrowVault {
        let renter_address = signer::address_of(renter);
        let vault = borrow_global_mut<EscrowVault>(@UnifiedCompute);

        assert!(table::contains<u64, Job>(&vault.jobs, job_id), E_JOB_NOT_FOUND);

        let job = table::borrow_mut<u64, Job>(&mut vault.jobs, job_id);
        assert!(job.renter_address == renter_address, E_UNAUTHORIZED);
        assert!(job.is_active, E_JOB_INACTIVE);

        let refund_amount = job.total_escrow_amount - job.claimed_amount;

        // Return whatever remains in the vault for this job
        let remaining_coins = table::remove<u64, Coin<AptosCoin>>(&mut vault.job_funds, job_id);
        if (refund_amount > 0) {
            // remaining_coins already equals leftover (claimed have been extracted)
            coin::deposit<AptosCoin>(renter_address, remaining_coins);
        } else {
            // If fully claimed, amount should be zero
            coin::destroy_zero<AptosCoin>(remaining_coins);
        };

        job.is_active = false;

        // Make listing available again
        marketplace::set_listing_available(job.host_address, job.listing_id);
    }
}
