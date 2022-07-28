# Load environment variables
source .env

# Deploy using script
forge script ./src/scripts/Deploy.sol:OlympusDeploy --sig "deploy(address,address)()" $GUARDIAN_ADDRESS $POLICY_ADDRESS --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --slow --verify --etherscan-api-key $ETHERSCAN_KEY -vv --resume