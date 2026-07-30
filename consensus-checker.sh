#!/bin/bash
# ================= CONFIGURATION =================
RPC="http://localhost:26657"
LCD="http://localhost:1317" 
INTERVAL=6
# =================================================

# Check if Bash 4.0+ is available (required for associative arrays)
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "Error: Bash 4.0 or higher is required."
    echo "macOS users: run 'brew install bash' and use '/opt/homebrew/bin/bash checker.sh'"
    exit 1
fi

# Check for required commands
for cmd in curl jq clear date awk sed; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: '$cmd' is required but not installed. Please install it first."
        exit 1
    fi
done

# Map Tendermint step numbers to names
get_step_name() {
    case $1 in
        1) echo "NewHeight" ;;
        2) echo "NewRound" ;;
        3) echo "Propose" ;;
        4) echo "Prevote" ;;
        5) echo "PrevoteWait" ;;
        6) echo "Precommit" ;;
        7) echo "PrecommitWait" ;;
        8) echo "Commit" ;;
        *) echo "Unknown($1)" ;;
    esac
}

clear
echo "Fetching validator list and monikers..."

declare -A PUBKEY_TO_MONIKER
declare -A ADDR_TO_MONIKER
declare -a RPC_ADDR_LIST

# 1. Fetch LCD validators and map pubkey -> moniker
lcd_res=$(curl -s --max-time 10 "$LCD/cosmos/staking/v1beta1/validators?pagination.limit=500&status=BOND_STATUS_BONDED")
while IFS='|' read -r pk moniker; do
    PUBKEY_TO_MONIKER["$pk"]="$moniker"
done < <(echo "$lcd_res" | jq -r '.validators[] | "\(.consensus_pubkey.key)|\(.description.moniker)"')

# 2. Fetch RPC validators and map address -> moniker
rpc_res=$(curl -s --max-time 10 "$RPC/validators?per_page=500")
while IFS='|' read -r addr pk; do
    moniker="${PUBKEY_TO_MONIKER[$pk]:-Unknown}"
    ADDR_TO_MONIKER["$addr"]="$moniker"
    RPC_ADDR_LIST+=("$addr")
done < <(echo "$rpc_res" | jq -r '.result.validators[] | "\(.address)|\(.pub_key.value)"')

total_validators=${#RPC_ADDR_LIST[@]}
if [ "$total_validators" -eq 0 ]; then
    echo "Failed to fetch validators. Check your RPC/LCD endpoints."
    exit 1
fi

# Catch Ctrl+C to exit cleanly
trap 'echo -e "\nStopped."; exit 0' INT

# Main loop
while true; do
    consensus=$(curl -s --max-time 10 "$RPC/consensus_state")

    hrs=$(echo "$consensus" | jq -r '.result.round_state["height/round/step"] // "0/0/0"')
    height=$(echo "$hrs" | cut -d'/' -f1)
    round=$(echo "$hrs" | cut -d'/' -f2)
    step_int=$(echo "$hrs" | cut -d'/' -f3)
    prop_addr=$(echo "$consensus" | jq -r '.result.round_state.proposer.address // ""')

    step_name=$(get_step_name "$step_int")
    prop_moniker="${ADDR_TO_MONIKER[$prop_addr]:-Unknown}"
    
    declare -A SIGNED_MAP
    signed_count=0
    
    # Fetch signatures from the previous block (Height - 1)
    if [ "$height" -gt 1 ] 2>/dev/null; then
        block_res=$(curl -s --max-time 10 "$RPC/block?height=$((height-1))")
        while read -r s_addr; do
            SIGNED_MAP["$s_addr"]=1
        done < <(echo "$block_res" | jq -r '.result.block.last_commit.signatures[]? | select(.block_id_flag == 2) | .validator_address')
    fi
    
    clear
    echo "Updated: $(date +'%H:%M:%S')"
    echo ""
    echo "Height : $height"
    echo "Round  : $round"
    echo "Step   : $step_name"
    echo "Proposer : $prop_moniker"
    echo ""
    
    # Configuration for the grid
    NUM_COLS=4
    NAME_MAX=25

    grid_input=""
    for addr in "${RPC_ADDR_LIST[@]}"; do
        moniker="${ADDR_TO_MONIKER[$addr]:-Unknown}"
        
        # MAGIC FIX: Replace all non-ASCII characters (emojis, symbols, etc.) with a single '*'
        # This forces bash/awk to count the width perfectly.
        moniker_clean=$(echo "$moniker" | LC_ALL=C sed -E 's/[^ -~]+/*/g')
        
        if [ "${SIGNED_MAP[$addr]+isset}" ]; then
            grid_input+="1"$'\t'"${moniker_clean}"$'\n'
            signed_count=$((signed_count + 1))
        else
            grid_input+="0"$'\t'"${moniker_clean}"$'\n'
        fi
    done

    # Native AWK script for grid formatting
    printf '%s' "$grid_input" | awk -F'\t' -v cols="$NUM_COLS" -v maxw="$NAME_MAX" '
    BEGIN {
        GREEN = "\033[32m"; RED = "\033[31m"; RESET = "\033[0m"
        idx = 0
    }
    NF == 2 {
        idx++
        status[idx] = $1
        name[idx] = substr($2, 1, maxw)
        len[idx] = length(name[idx])
    }
    END {
        total = idx
        if (total == 0) exit
        grid_rows = int((total + cols - 1) / cols)
        num_width = length(total)
        
        # Find max length per column
        for (i = 1; i <= total; i++) {
            c = int((i - 1) / grid_rows)
            if (len[i] > col_w[c]) col_w[c] = len[i]
        }
        
        # Print grid row by row
        for (r = 0; r < grid_rows; r++) {
            line = ""
            for (c = 0; c < cols; c++) {
                i = c * grid_rows + r + 1
                if (i <= total) {
                    if (status[i] == "1") dot = GREEN "●" RESET
                    else dot = RED "●" RESET
                    
                    num_str = sprintf("%*d", num_width, i)
                    pad = col_w[c] - len[i] + 2
                    line = line num_str " " dot " " name[i] sprintf("%*s", pad, "")
                }
            }
            print line
        }
    }'

    echo ""
    echo "Signed: $signed_count / $total_validators"
    
    unset SIGNED_MAP
    sleep $INTERVAL
done
