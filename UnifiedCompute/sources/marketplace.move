// File: sources/marketplace.move
module UnifiedCompute::marketplace {
    use std::string::{String, utf8};
    use std::option::{Option, none};
    use std::signer;

    // === Custom Errors ===
    const E_PRICE_MUST_BE_GREATER_THAN_ZERO: u64 = 1;

    // === Data Structures ===
    
    // Note: 'copy' is intentionally left out of the top-level structs
    // to ensure they are treated like resources (moved, not copied).
    struct CloudDetails has store, drop {
        provider: String,
        instance_id: String,
        instance_type: String,
        region: String,
    }

    struct PhysicalSpecs has store, drop {
        gpu_model: String,
        cpu_cores: u64,
        ram_gb: u64,
    }

    enum ListingType has store, drop {
        Cloud(CloudDetails),
        Physical(PhysicalSpecs),
    }

    // THIS IS THE CORRECTED LINE: No more 'resource' keyword.
    // The 'key' ability designates it as a top-level resource storable in an account.
    struct Listing has key {
        listing_type: ListingType,
        price_per_second: u64, // In smallest unit of currency (Octas)
        is_available: bool,
        host: address,
        active_job_id: Option<u64>,
    }

    // === Public Functions ===

    /// Creates a new Listing and stores it under the host's account.
    public entry fun list_machine(
        host: &signer,
        // For simplicity, we'll pass individual fields instead of complex structs
        // which are difficult to construct from the CLI.
        is_physical: bool,
        gpu_or_instance_type: String,
        price_per_second: u64
    ) {
        assert!(price_per_second > 0, E_PRICE_MUST_BE_GREATER_THAN_ZERO);

        let host_addr = signer::address_of(host);
        
        let listing_type = if (is_physical) {
            ListingType::Physical(PhysicalSpecs {
                gpu_model: gpu_or_instance_type,
                cpu_cores: 16, // Dummy value for now
                ram_gb: 32,    // Dummy value for now
            })
        } else {
            ListingType::Cloud(CloudDetails {
                provider: utf8(b"AWS"),
                instance_id: utf8(b"i-12345abcdef"), // Dummy value
                instance_type: gpu_or_instance_type,
                region: utf8(b"us-east-1"), // Dummy value
            })
        };

        // move_to stores the resource directly under the signer's account
        move_to(host, Listing {
            listing_type,
            price_per_second,
            is_available: true,
            host: host_addr,
            active_job_id: none(),
        });
    }

    #[test(host = @0x123)]
    fun test_list_physical_machine(host: &signer) {
        list_machine(host, true, utf8(b"NVIDIA RTX 4090"), 100);
        let host_addr = signer::address_of(host);
        assert!(exists<Listing>(host_addr), 0);
    }
}