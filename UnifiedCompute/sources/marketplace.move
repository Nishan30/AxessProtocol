module UnifiedCompute::marketplace {
    use std::string::{String};
    use std::option::{Option, some, none};
    use std::signer;
    use std::vector;

    friend UnifiedCompute::escrow;

    const E_LISTING_NOT_FOUND: u64 = 1;
    const E_LISTING_NOT_AVAILABLE: u64 = 3;
    const E_UNAUTHORIZED: u64 = 4;
    const E_ONLY_ONE_LISTING_ALLOWED: u64 = 5;
    const E_PRICE_TOO_HIGH: u64 = 6;
    const E_INSUFFICIENT_SPECS: u64 = 7;

    struct CloudDetails has store, drop, copy { provider: String, instance_id: String, instance_type: String, region: String }
    struct PhysicalSpecs has store, drop, copy { gpu_model: String, cpu_cores: u64, ram_gb: u64 }
    enum ListingType has store, drop, copy { Cloud(CloudDetails), Physical(PhysicalSpecs) }

    struct Listing has key {
        listing_type: ListingType,
        price_per_second: u64,
        is_available: bool,
        is_rented: bool,
        active_job_id: Option<u64>,
        host_public_key: vector<u8>,
    }

    /// A public, copyable struct that acts as a "view" of the Listing's data.
    public struct ListingView has store, copy, drop {
        listing_type: ListingType,
        price_per_second: u64,
        is_available: bool,
        is_rented: bool,
        active_job_id: Option<u64>,
    }

    // --- PUBLIC GETTERS FOR THE ListingView STRUCT ---
    public fun view_listing_type(view: &ListingView): &ListingType { &view.listing_type }
    public fun view_price_per_second(view: &ListingView): u64 { view.price_per_second }
    public fun view_is_available(view: &ListingView): bool { view.is_available }
    public fun view_is_rented(view: &ListingView): bool { view.is_rented }
    public fun view_active_job_id(view: &ListingView): &Option<u64> { &view.active_job_id }


    /// Called by escrow to verify a listing meets all job requirements.
    public(friend) fun verify_listing_is_acceptable(
        host_address: address,
        max_price_per_second: u64,
        required_cpu_cores: u64,
        required_ram_gb: u64,
    ) acquires Listing {
        assert!(exists<Listing>(host_address), E_LISTING_NOT_FOUND);
        let listing = borrow_global<Listing>(host_address);
        assert!(listing.price_per_second <= max_price_per_second, E_PRICE_TOO_HIGH);
        match (listing.listing_type) {
            ListingType::Physical(specs) => {
                assert!(specs.cpu_cores >= required_cpu_cores, E_INSUFFICIENT_SPECS);
                assert!(specs.ram_gb >= required_ram_gb, E_INSUFFICIENT_SPECS);
            },
            ListingType::Cloud(_) => {
                abort E_INSUFFICIENT_SPECS
            },
        }
    }

    public entry fun register_host_machine(
        host: &signer, gpu_model: String, cpu_cores: u64, ram_gb: u64,
        price_per_second: u64, host_public_key: vector<u8>
    ) {
        let host_addr = signer::address_of(host);
        assert!(!exists<Listing>(host_addr), E_ONLY_ONE_LISTING_ALLOWED);
        let new_listing = Listing {
            listing_type: ListingType::Physical(PhysicalSpecs { gpu_model, cpu_cores, ram_gb }),
            price_per_second, is_available: false, is_rented: false,
            active_job_id: none(), host_public_key
        };
        move_to(host, new_listing);
    }

    public entry fun set_availability(host: &signer, is_available: bool) acquires Listing {
        let host_addr = signer::address_of(host);
        assert!(exists<Listing>(host_addr), E_LISTING_NOT_FOUND);
        let listing = borrow_global_mut<Listing>(host_addr);
        if (is_available) { assert!(!listing.is_rented, E_LISTING_NOT_AVAILABLE) };
        listing.is_available = is_available;
    }

    public(friend) fun claim_listing_for_rent(host_address: address, job_id: u64): u64 acquires Listing {
        assert!(exists<Listing>(host_address), E_LISTING_NOT_FOUND);
        let listing = borrow_global_mut<Listing>(host_address);
        assert!(listing.is_available && !listing.is_rented, E_LISTING_NOT_AVAILABLE);
        listing.is_rented = true;
        listing.is_available = false;
        listing.active_job_id = some(job_id);
        listing.price_per_second
    }

    public(friend) fun release_listing_after_rent(host_address: address) acquires Listing {
        assert!(exists<Listing>(host_address), E_LISTING_NOT_FOUND);
        let listing = borrow_global_mut<Listing>(host_address);
        listing.is_rented = false;
        listing.active_job_id = none();
        listing.is_available = false;
    }

    /// Returns a safe, copyable view of the listing's data.
    #[view]
    public fun get_listing_view(host_address: address): ListingView acquires Listing {
        assert!(exists<Listing>(host_address), E_LISTING_NOT_FOUND);
        let listing_ref = borrow_global<Listing>(host_address);
        ListingView {
            listing_type: listing_ref.listing_type,
            price_per_second: listing_ref.price_per_second,
            is_available: listing_ref.is_available,
            is_rented: listing_ref.is_rented,
            active_job_id: listing_ref.active_job_id,
        }
    }
}