module UnifiedCompute::marketplace {
    use std::string::{String, utf8};
    use std::option::{Option, some, none};
    use std::signer;
    use std::vector;

    friend UnifiedCompute::escrow;

    const E_LISTING_NOT_FOUND: u64 = 1;
    const E_MAX_LISTINGS_REACHED: u64 = 2;
    const E_LISTING_NOT_AVAILABLE: u64 = 3;

    struct Listing has store, copy, drop {
        id: u64,
        listing_type: ListingType,
        price_per_second: u64,
        is_available: bool,
        active_job_id: Option<u64>,
        host_public_key: vector<u8>, 
    }

    public fun is_available(listing: &Listing): bool { listing.is_available }
    public fun host_public_key(listing: &Listing): vector<u8> { listing.host_public_key }

    struct CloudDetails has store, drop, copy { provider: String, instance_id: String, instance_type: String, region: String }
    struct PhysicalSpecs has store, drop, copy { gpu_model: String, cpu_cores: u64, ram_gb: u64 }
    enum ListingType has store, drop, copy { Cloud(CloudDetails), Physical(PhysicalSpecs) }
    struct ListingManager has key { listings: vector<Listing>, next_listing_id: u64 }

    // --- NEW CONSTANT ---
    const E_UNAUTHORIZED: u64 = 4;

    // --- Helper function to find a listing's index. This is more efficient. ---
    fun find_listing_index(manager: &ListingManager, listing_id: u64): (bool, u64) {
        let i = 0;
        while (i < vector::length(&manager.listings)) {
            let listing = vector::borrow(&manager.listings, i);
            if (listing.id == listing_id) {
                return (true, i)
            };
            i = i + 1;
        };
        (false, 0)
    }

    fun get_or_create_manager(host: &signer) {
        let host_addr = signer::address_of(host);
        if (!exists<ListingManager>(host_addr)) {
            move_to(host, ListingManager { listings: vector::empty(), next_listing_id: 0 });
        };
    }

    /// Creates a new listing for a physical machine with its full specs.
    public entry fun list_physical_machine(
        host: &signer,
        gpu_model: String,
        cpu_cores: u64,
        ram_gb: u64,
        price_per_second: u64,
        host_public_key: vector<u8>
    ) acquires ListingManager {
       get_or_create_manager(host);
        let host_addr = signer::address_of(host);
        let manager = borrow_global_mut<ListingManager>(host_addr);
        assert!(vector::length(&manager.listings) < 10, E_MAX_LISTINGS_REACHED);

        let listing_type = ListingType::Physical(PhysicalSpecs {
            gpu_model,
            cpu_cores,
            ram_gb,
        });

        let new_listing = Listing {
            id: manager.next_listing_id,
            listing_type,
            price_per_second,
            is_available: true,
            active_job_id: none(),
            host_public_key
        };
        vector::push_back(&mut manager.listings, new_listing);
        manager.next_listing_id = manager.next_listing_id + 1;
    }

    /// Creates a new listing for a cloud instance.
    public entry fun list_cloud_machine(
        host: &signer,
        instance_type: String,
        price_per_second: u64,
        host_public_key: vector<u8>
    ) acquires ListingManager {
        get_or_create_manager(host);
        let host_addr = signer::address_of(host);
        let manager = borrow_global_mut<ListingManager>(host_addr);
        assert!(vector::length(&manager.listings) < 10, E_MAX_LISTINGS_REACHED);

        let listing_type = ListingType::Cloud(CloudDetails {
            provider: utf8(b"AWS"),
            instance_id: utf8(b"i-placeholder"),
            instance_type,
            region: utf8(b"us-east-1"),
        });

        let new_listing = Listing {
            id: manager.next_listing_id,
            listing_type,
            price_per_second,
            is_available: true,
            active_job_id: none(),
            host_public_key
        };
        vector::push_back(&mut manager.listings, new_listing);
        manager.next_listing_id = manager.next_listing_id + 1;
    }

    public entry fun delist_machine(host: &signer, listing_id: u64) acquires ListingManager {
        let host_addr = signer::address_of(host);
        assert!(exists<ListingManager>(host_addr), E_UNAUTHORIZED);
        let manager = borrow_global_mut<ListingManager>(host_addr);

        let (found, index) = find_listing_index(manager, listing_id);
        assert!(found, E_LISTING_NOT_FOUND);

        let listing = vector::borrow(&manager.listings, index);
        // A host can only delist a machine if it's not currently rented.
        assert!(listing.is_available, E_LISTING_NOT_AVAILABLE);

        // This safely removes the element from the vector by its index.
        vector::swap_remove(&mut manager.listings, index);
    }

    // --- NEW, ENCAPSULATED FRIEND FUNCTION ---
    // This function is called by escrow. It handles all state changes for the marketplace.
    // It finds the listing, checks if it's available, marks it as rented, and returns the price.
    public(friend) fun claim_listing_for_rent(
        host_address: address, listing_id: u64, job_id: u64
    ): u64 acquires ListingManager {
        let manager = borrow_global_mut<ListingManager>(host_address);
        let (found, index) = find_listing_index(manager, listing_id);
        assert!(found, E_LISTING_NOT_FOUND);

        let listing = vector::borrow_mut(&mut manager.listings, index);
        assert!(listing.is_available, E_LISTING_NOT_AVAILABLE);
        listing.is_available = false;
        listing.active_job_id = some(job_id);
        return listing.price_per_second
    }

    public(friend) fun set_listing_available(host_address: address, listing_id: u64) acquires ListingManager {
        let manager = borrow_global_mut<ListingManager>(host_address);
        let (found, index) = find_listing_index(manager, listing_id);
        assert!(found, E_LISTING_NOT_FOUND);
        
        let listing = vector::borrow_mut(&mut manager.listings, index);
        listing.is_available = true;
        listing.active_job_id = none();
    }

    // --- NEW: A simple admin function for a host to reset their own listing ---
    // This is safer than a generic function.
    public entry fun force_reset_listing_as_host(host: &signer, listing_id: u64) acquires ListingManager {
        let host_addr = signer::address_of(host);
        assert!(exists<ListingManager>(host_addr), E_UNAUTHORIZED);
        let manager = borrow_global_mut<ListingManager>(host_addr);

        let (found, index) = find_listing_index(manager, listing_id);
        assert!(found, E_LISTING_NOT_FOUND);

        let listing_mut = vector::borrow_mut(&mut manager.listings, index);
        listing_mut.is_available = true;
        listing_mut.active_job_id = none();
    }

    #[view]
    public fun get_listings_by_host(host_address: address): vector<Listing> acquires ListingManager {
        if (!exists<ListingManager>(host_address)) { return vector::empty() };
        let manager = borrow_global<ListingManager>(host_address);

        // build an owned vector by copying each Listing (Listing has `copy`)
        let out = vector::empty<Listing>();
        let i = 0;
        while (i < vector::length(&manager.listings)) {
            let l = *vector::borrow(&manager.listings, i);
            vector::push_back(&mut out, l);
            i = i + 1;
        };
        out
    }

    #[view]
    public fun get_listing_by_id(host_address: address, listing_id: u64): Listing acquires ListingManager {
        if (!exists<ListingManager>(host_address)) { abort E_LISTING_NOT_FOUND };
        let manager = borrow_global<ListingManager>(host_address);

        let i = 0;
        while (i < vector::length(&manager.listings)) {
            let listing_ref = vector::borrow(&manager.listings, i);
            if (listing_ref.id == listing_id) { return *listing_ref };
            i = i + 1;
        };
        abort E_LISTING_NOT_FOUND
    }
}