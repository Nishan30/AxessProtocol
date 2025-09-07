module UnifiedCompute::reputation {
    use std::signer;
    use std::option::{Self, Option};
    use aptos_std::table::{Self, Table};

    // The escrow module is the only one authorized to update reputation scores.
    friend UnifiedCompute::escrow;

    /// A record of a host's performance.
    struct ReputationScore has key, store, copy, drop {
        completed_jobs: u64,
        total_uptime_seconds: u64,
    }

    /// This resource, stored at the contract's address, holds the reputation table.
    struct ReputationVault has key {
        scores: Table<address, ReputationScore>,
    }

    /// This should be called once by the contract owner during deployment.
    public entry fun initialize_vault(sender: &signer) {
        let sender_addr = signer::address_of(sender);
        assert!(sender_addr == @UnifiedCompute, 1); // E_UNAUTHORIZED
        if (!exists<ReputationVault>(sender_addr)) {
            move_to(sender, ReputationVault {
                scores: table::new<address, ReputationScore>(),
            });
        }
    }

    /// Called by the escrow contract to update a host's reputation after a job.
    public(friend) fun record_job_completion(
        host_address: address,
        job_duration_seconds: u64
    ) acquires ReputationVault {
        let vault = borrow_global_mut<ReputationVault>(@UnifiedCompute);
        
        // If the host has no score yet, create one.
        if (!table::contains(&vault.scores, host_address)) {
            let new_score = ReputationScore {
                completed_jobs: 0,
                total_uptime_seconds: 0,
            };
            table::add(&mut vault.scores, host_address, new_score);
        };

        // Update the score.
        let score = table::borrow_mut(&mut vault.scores, host_address);
        score.completed_jobs = score.completed_jobs + 1;
        score.total_uptime_seconds = score.total_uptime_seconds + job_duration_seconds;
    }

    /// A view function for anyone to read a host's reputation.
    #[view]
    public fun get_host_reputation(host_address: address): Option<ReputationScore> acquires ReputationVault {
        if (!exists<ReputationVault>(@UnifiedCompute)) { return option::none() };
        let vault = borrow_global<ReputationVault>(@UnifiedCompute);
        if (table::contains(&vault.scores, host_address)) {
            option::some(*table::borrow(&vault.scores, host_address))
        } else {
            option::none()
        }
    }
}