#!/bin/bash

# Load config from .env (same directory as script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env"

# Set paths from env
pendingPredictions="${PREDICTIONS_DIR}/pendingPredictions.txt"
pendingPredictionsTemp="${pendingPredictions}.t"
resolvedPredictions="${PREDICTIONS_DIR}/resolvedPredictions.txt"
hashesFile="${PREDICTIONS_DIR}/hashes.txt"

# Solana CLI path
SOLANA_CLI="$HOME/.local/share/solana/install/active_release/bin/solana"

# Determine cluster for explorer URLs
if [[ "$SOLANA_RPC" == *"devnet"* ]]; then
        SOLANA_CLUSTER="devnet"
elif [[ "$SOLANA_RPC" == *"testnet"* ]]; then
        SOLANA_CLUSTER="testnet"
else
        SOLANA_CLUSTER="mainnet"
fi

# Convert base58 private key to temp keypair file for Solana CLI
function get_keypair_file(){
        local tmpfile=$(mktemp)
        echo "$SOLANA_PRIVATE_KEY" | python3 -c "
import sys, json, base58
key = base58.b58decode(sys.stdin.read().strip())
print(json.dumps(list(key)))
" > "$tmpfile"
        echo "$tmpfile"
}

# Send hash to Solana as memo, return tx signature
function send_to_solana(){
        local hash=$1
        local keypair_file=$(get_keypair_file)
        local pubkey=$($SOLANA_CLI address -k "$keypair_file")

        # Send 0 SOL to self with memo
        local tx_sig=$($SOLANA_CLI transfer "$pubkey" 0 \
                --from "$keypair_file" \
                --url "$SOLANA_RPC" \
                --with-memo "$hash" \
                --allow-unfunded-recipient \
                --fee-payer "$keypair_file" \
                2>/dev/null | grep -oE '[A-Za-z0-9]{87,88}' | head -1)

        rm "$keypair_file"
        echo "$tx_sig"
}

function predict(){
        read -p "> Statement: " statement
        read -p "> Probability (%): " probability
        read -p "> Date of resolution (year/month/day): " date

        # Generate salt and hash for blockchain commitment
        salt=$(openssl rand -hex 16)
        hash=$(echo -n "${statement}|${probability}|${date}|${salt}" | sha256sum | cut -d' ' -f1)

        # Save prediction locally
        echo -e "UNRESOLVED\t$date\t$probability\t$statement" >> "$pendingPredictions"

        # Send hash to Solana
        echo "Sending to Solana..."
        tx_sig=$(send_to_solana "$hash")

        if [ -n "$tx_sig" ]; then
                echo -e "${hash}\t${salt}\t${tx_sig}\t${date}\t${probability}\t${statement}" >> "$hashesFile"
                echo "Hash: $hash"
                echo "Tx: $tx_sig"
                if [ "$SOLANA_CLUSTER" = "mainnet" ]; then
                        echo "View: https://explorer.solana.com/tx/${tx_sig}"
                else
                        echo "View: https://explorer.solana.com/tx/${tx_sig}?cluster=${SOLANA_CLUSTER}"
                fi
        else
                echo -e "${hash}\t${salt}\tFAILED\t${date}\t${probability}\t${statement}" >> "$hashesFile"
                echo "Hash: $hash"
                echo "Warning: Solana transaction failed"
        fi
}

function resolve(){
        while IFS= read -r -u9 line || [[ -n "$line" ]]; do

                resolutionState="$(cut -d'	' -f1 <<<"$line")"
                date="$(cut -d'	' -f2 <<<"$line")"
                probability="$(cut -d'	' -f3 <<<"$line")"
                statement="$(cut -d'	' -f4 <<<"$line")"
                
                today=$(date +"%Y/%m/%d") 
                if [[ "$today" > "$date" ]]; 
                then
                        # Already resolved
                        echo $statement "("$date")"
                        read -p "> (TRUE/FALSE) " resolutionState
                        echo -e "$resolutionState\t$date\t$probability\t$statement" >> $resolvedPredictions
                else
                        # Not yet resolved
                        echo -e "$resolutionState\t$date\t$probability\t$statement" >> "$pendingPredictionsTemp"
                fi
        done 9< "$pendingPredictions"

        # Replace pending file (create empty if no pending predictions left)
        if [ -f "$pendingPredictionsTemp" ]; then
                mv "$pendingPredictionsTemp" "$pendingPredictions"
        else
                > "$pendingPredictions"
        fi
}

# Verify a single prediction by recalculating hash and checking Solana
function verify_single(){
        local stored_hash=$1
        local salt=$2
        local tx_sig=$3
        local date=$4
        local probability=$5
        local statement=$6

        # Skip if no tx signature
        if [ "$tx_sig" = "PENDING" ] || [ "$tx_sig" = "FAILED" ]; then
                echo "[SKIP] $statement - no tx on chain"
                return
        fi

        # Recalculate hash
        local recalc_hash=$(echo -n "${statement}|${probability}|${date}|${salt}" | sha256sum | cut -d' ' -f1)

        # Fetch tx from Solana and extract memo (with retry on rate limit)
        local tx_data=""
        local max_retries=3
        for ((attempt=1; attempt<=max_retries; attempt++)); do
                local response=$(curl -s -i -X POST "$SOLANA_RPC" \
                        -H "Content-Type: application/json" \
                        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getTransaction\",\"params\":[\"$tx_sig\",{\"encoding\":\"jsonParsed\",\"maxSupportedTransactionVersion\":0}]}")

                # Split headers and body
                local headers=$(echo "$response" | sed '/^\r$/q')
                tx_data=$(echo "$response" | sed '1,/^\r$/d')

                if echo "$tx_data" | grep -q '"code": 429'; then
                        local retry_after=$(echo "$headers" | grep -i 'Retry-After' | cut -d':' -f2 | tr -d ' \r')
                        retry_after=${retry_after:-2}
                        sleep "$retry_after"
                else
                        break
                fi
        done

        local memo=$(echo "$tx_data" | python3 -c "
import sys, json
data = json.load(sys.stdin)
try:
    logs = data['result']['meta']['logMessages']
    for log in logs:
        if 'Memo' in log:
            # Extract hash from memo log
            parts = log.split('\"')
            if len(parts) >= 2:
                print(parts[1])
                break
except:
    pass
" 2>/dev/null)

        # Get block time
        local block_time=$(echo "$tx_data" | python3 -c "
import sys, json
from datetime import datetime
data = json.load(sys.stdin)
try:
    ts = data['result']['blockTime']
    print(datetime.utcfromtimestamp(ts).strftime('%Y-%m-%d %H:%M:%S UTC'))
except:
    print('unknown')
" 2>/dev/null)

        # Compare
        if [ "$recalc_hash" = "$stored_hash" ] && [ "$memo" = "$stored_hash" ]; then
                echo "[OK] $statement"
                echo "     Committed: $block_time"
        elif [ "$recalc_hash" != "$stored_hash" ]; then
                echo "[FAIL] $statement - local hash mismatch"
        elif [ -z "$memo" ]; then
                echo "[FAIL] $statement - could not fetch memo from Solana"
        else
                echo "[FAIL] $statement - chain hash mismatch"
        fi
}

# List predictions and verify selected one
function verify(){
        if [ ! -f "$hashesFile" ]; then
                echo "No predictions to verify"
                return
        fi

        # Show numbered list
        echo "Predictions:"
        local i=1
        while IFS=$'\t' read -r hash salt tx_sig date probability statement; do
                local status="ON CHAIN"
                [ "$tx_sig" = "PENDING" ] || [ "$tx_sig" = "FAILED" ] && status="$tx_sig"
                echo "$i. $statement ($date) - $status"
                ((i++))
        done < "$hashesFile"

        echo ""
        read -p "> Select number to verify: " selection

        # Get selected line
        local line=$(sed -n "${selection}p" "$hashesFile")
        if [ -z "$line" ]; then
                echo "Invalid selection"
                return
        fi

        local hash=$(echo "$line" | cut -d$'\t' -f1)
        local salt=$(echo "$line" | cut -d$'\t' -f2)
        local tx_sig=$(echo "$line" | cut -d$'\t' -f3)
        local date=$(echo "$line" | cut -d$'\t' -f4)
        local probability=$(echo "$line" | cut -d$'\t' -f5)
        local statement=$(echo "$line" | cut -d$'\t' -f6)

        echo ""
        verify_single "$hash" "$salt" "$tx_sig" "$date" "$probability" "$statement"
}

# Verify all predictions
function verifyall(){
        if [ ! -f "$hashesFile" ]; then
                echo "No predictions to verify"
                return
        fi

        echo "Verifying all predictions..."
        echo ""

        while IFS=$'\t' read -r hash salt tx_sig date probability statement; do
                verify_single "$hash" "$salt" "$tx_sig" "$date" "$probability" "$statement"
                sleep 2  # Avoid rate limiting on public RPC
        done < "$hashesFile"
}

function tally(){
        
        numTRUEtens=0
        numFALSEtens=0
        for i in {0..100}
        do

                regExPatternTRUE="^TRUE.*	${i}	"
                regExPatternFALSE="^FALSE.*	${i}	"
                numTRUE="$(grep -c -e "$regExPatternTRUE" $resolvedPredictions)"
                numFALSE="$(grep -c -e "$regExPatternFALSE" $resolvedPredictions)"

                numTRUEtens=$((numTRUEtens+numTRUE))
                numFALSEtens=$((numFALSEtens+numFALSE))
                if [ $(( $i % 10 )) -eq 0 ]  && [ $i -ne 0 ] ; then
                        echo $((i-10)) to $i : $numTRUEtens TRUE and $numFALSEtens FALSE
                        numTRUEtens=0
                        numFALSEtens=0
                fi
        done

}
