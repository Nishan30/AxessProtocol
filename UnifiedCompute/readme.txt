# 1. Check for errors
aptos move compile

# 2. Deploy the contracts to your account
#    (Replace 'default' if your profile has a different name)
aptos move publish --named-addresses UnifiedCompute=default --profile default

# 3. After getting your contract address from the output above, run these:
#    (Replace YOUR_CONTRACT_ADDRESS)
aptos move run --function-id YOUR_CONTRACT_ADDRESS::escrow::initialize_vault --profile default
aptos move run --function-id YOUR_CONTRACT_ADDRESS::reputation::initialize_vault --profile default