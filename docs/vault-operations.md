# Vault Initialization and Unseal

Initialization is a one-time operation. It creates the Shamir unseal keys and
initial root token. These values must never be committed to Git, pasted into
tickets, or stored in pipeline logs.

## Demo procedure

Choose an approved local encrypted location outside the repository:

```bash
export VAULT_KEY_FILE=/secure/location/vault-init.json
OC_BIN=oc ./scripts/vault/initialize-and-unseal.sh "$VAULT_KEY_FILE"
```

The script:

1. Initializes `vault-0` with five key shares and a threshold of three.
2. Writes the output with mode `0600` without printing it.
3. Unseals all three Raft members with the first three key shares.
4. Prints only the final Vault status.

Confirm the Raft cluster after authenticating with the initial root token:

```bash
export VAULT_ADDR=https://VAULT_ROUTE
vault login
vault operator raft list-peers
```

Move the five key shares and initial root token into the approved custody
process immediately. For a customer deployment, use separate custodians or an
approved auto-unseal service. Do not leave initialization material on a shared
bastion host.

After every Vault pod restart, Shamir-sealed Vault must be unsealed again using
three distinct key shares. The same script can perform only the unseal portion
when the protected initialization file is available.
