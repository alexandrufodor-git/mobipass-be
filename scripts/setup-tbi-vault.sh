#!/bin/bash
# Insert TBI RSA keys into Supabase Vault (local dev).
#
# TBI provides two key pairs (PDF: "Two pairs of encryption keys are provided
# by TBI integration team"). They are NOT a matching pair — direction matters:
#
#   SFTL pair:     we encrypt outgoing /Finalize + /CanceledByCustomer with the
#                  PUBLIC half. TBI keeps the private half to decrypt.
#   Merchant pair: TBI encrypts ReturnToProvider callbacks with the PUBLIC
#                  half. We keep the PRIVATE half to decrypt.
#
# Wrong slots = TBI rejects everything (or we receive garbage from callbacks).

CONTAINER="supabase_db_mobi-pass-be"
KEY_DIR="/Users/machita/Downloads/DOCUMENTATIE TEST API"

# SFTL public — encrypts everything we send to TBI.
OUTGOING_PUB=$(cat "${KEY_DIR}/Chei_SFTL_tbitestapi_ro/pub.pem")
# Merchant ("Comerciant") private — decrypts TBI callbacks to our webhook.
CALLBACK_PRIV=$(cat "${KEY_DIR}/Chei_Comerciant_tbitestapi_ro/priv_key.pem")

# Clean up any prior entries (old names + idempotent re-runs)
docker exec "$CONTAINER" psql -U postgres -c "DELETE FROM vault.secrets WHERE name IN ('tbi_public_key','tbi_private_key','tbi_outgoing_pub','tbi_callback_priv');" >/dev/null

echo "Inserting tbi_outgoing_pub into Vault..."
docker exec "$CONTAINER" psql -U postgres -c "SELECT vault.create_secret(\$\$${OUTGOING_PUB}\$\$, 'tbi_outgoing_pub');"

echo "Inserting tbi_callback_priv into Vault..."
docker exec "$CONTAINER" psql -U postgres -c "SELECT vault.create_secret(\$\$${CALLBACK_PRIV}\$\$, 'tbi_callback_priv');"

echo "Verifying..."
docker exec "$CONTAINER" psql -U postgres -c "SELECT name FROM vault.decrypted_secrets WHERE name IN ('tbi_outgoing_pub', 'tbi_callback_priv');"
