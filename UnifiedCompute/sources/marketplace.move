// ------------------------------------------------------------------
// --- MODULE: UnifiedCompute::marketplace
// --- RESPONSIBILITY: Manages host machine registration and availability.
// --- MODEL: One Machine, One Listing Per Host
// ------------------------------------------------------------------
module UnifiedCompute::marketplace {
    use std::string::{String};
    use std::option::{Option, some, none};
    use std::signer;
    use std::vector;

    // The escrow module is the only one authorized to change the rental state.
    friend UnifiedCompute::escrow;

    // --- All Constants ---
    const E_LISTING_NOT_FOUND: u64 = 1;
    const E_LISTING_NOT_AVAILABLE: u64 = 3;
    const E_UNAUTHORIZED: u64 = 4;
    // --- NEW: A specific error for this new model ---
    const E_ONLY_ONE_LISTING_ALLOWED: u64 = 5;

    // --- Struct Definitions ---
    // These remain the same but are used within the new Listing resource.
    struct CloudDetails has store, drop, copy { provider: String, instance_id: String, instance_type: String, region: String }
    struct PhysicalSpecs has store, drop, copy { gpu_model: String, cpu_cores: u64, ram_gb: u64 }
    enum ListingType has store, drop, copy { Cloud(CloudDetails), Physical(PhysicalSpecs) }

    // --- UPDATED: The Listing resource is now the top-level object for a host ---
    // It has `key`, meaning one instance of this resource is stored directly
    // under each host's account address. The ListingManager is no longer needed.
    struct Listing has key {
        listing_type: ListingType,
        price_per_second: u64,
        // --- NEW: Granular state flags ---
        is_available: bool, // Controlled by the host agent: "am I online and ready?"
        is_rented: bool,    // Controlled by the escrow contract: "am I currently doing a job?"
        active_job_id: Option<u64>,
        host_public_key: vector<u8>,
    }


    // --- Core Public Functions ---

    /// A host calls this function ONLY ONCE to register their machine's permanent specs.
    /// This creates the `Listing` resource under their account.
    public entry fun register_host_machine(
        host: &signer,
        gpu_model: String,
        cpu_cores: u64,
        ram_gb: u64,
        price_per_second: u64,
        host_public_key: vector<u8>
    ) {
        let host_addr = signer::address_of(host);
        // This assertion ensures a host can never have more than one listing resource.
        assert!(!exists<Listing>(host_addr), E_ONLY_ONE_LISTING_ALLOWED);

        let new_listing = Listing {
            listing_type: ListingType::Physical(PhysicalSpecs { gpu_model, cpu_cores, ram_gb }),
            price_per_second,
            is_available: false, // Machine starts offline by default.
            is_rented: false,
            active_job_id: none(),
            host_public_key
        };
        move_to(host, new_listing);
    }

    /// The host's off-chain agent calls this on startup and shutdown to signal its readiness.
    /// This function allows a host to appear "online" or "offline" in the marketplace.
    public entry fun set_availability(host: &signer, is_available: bool) acquires Listing {
        let host_addr = signer::address_of(host);
        assert!(exists<Listing>(host_addr), E_LISTING_NOT_FOUND);
        let listing = borrow_global_mut<Listing>(host_addr);

        // A host can only mark their machine as available if it's not currently rented.
        // This prevents a machine from accepting new jobs while finishing an old one.
        if (is_available) {
            assert!(!listing.is_rented, E_LISTING_NOT_AVAILABLE);
        }
        listing.is_available = is_available;
    }


    // --- Friend Functions (for Escrow contract only) ---

    /// The escrow contract calls this to lock a listing for a new job.
    /// It returns the price_per_second for the escrow to calculate the total cost.
    public(friend) fun claim_listing_for_rent(
        host_address: address, job_id: u64
    ): u64 acquires Listing {
        assert!(exists<Listing>(host_address), E_LISTING_NOT_FOUND);
        let listing = borrow_global_mut<Listing>(host_address);

        // This is the critical check: the agent must be online AND not already rented.
        assert!(listing.is_available && !listing.is_rented, E_LISTING_NOT_AVAILABLE);

        listing.is_rented = true;
        listing.is_available = false; // Set unavailable for safety during the job.
        listing.active_job_id = some(job_id);
        return listing.price_per_second
    }

    /// The escrow contract calls this to release the lock on a listing after a job is completed or terminated.
    public(friend) fun release_listing_after_rent(host_address: address) acquires Listing {
        assert!(exists<Listing>(host_address), E_LISTING_NOT_FOUND);
        let listing = borrow_global_mut<Listing>(host_address);

        listing.is_rented = false;
        listing.active_job_id = none();
        // IMPORTANT: We do NOT automatically set is_available back to true.
        // The host's off-chain agent must explicitly call set_availability(true)
        // to confirm it's ready for the next job. This makes the system more robust.
        listing.is_available = false;
    }


    // --- View Function ---

    /// A simple view function to get all the details of a single host's listing.
    /// The frontend or other services can call this to check a machine's status and specs.
    #[view]
    public fun get_listing(host_address: address): Listing acquires Listing {
        assert!(exists<Listing>(host_address), E_LISTING_NOT_FOUND);
        // Borrows and returns a copy of the Listing resource.
        *borrow_global<Listing>(host_address)
    }
}