# Debug trace — uncomment for verbose logging when troubleshooting auth issues
# set -x

getSHA256() {
    echo -n "$1" | sha256sum | cut -d' ' -f1
}

# Cross-platform date helper: GNU date (Linux) vs BSD date (macOS)
# Usage: date_epoch_offset <base_epoch_or_iso> <seconds_to_add>
date_epoch_offset() {
    local base="$1"
    local offset="$2"
    if date -d @0 >/dev/null 2>&1; then
        # GNU/Linux
        date -d "@$base + $offset seconds" +%s
    else
        # macOS/BSD: convert base to epoch first, then add offset
        local epoch
        epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$(date -r "$base" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$base")" +%s 2>/dev/null)
        if [ -n "$epoch" ]; then
            echo $(( epoch + offset ))
        else
            # fallback: treat base as epoch already
            echo $(( base + offset ))
        fi
    fi
}

XClaim=$(date +%s)
host="https://hanime.tv"
session_file="htv.session"
# hanime.tv signature construction (observed from their app2 API)
XSig=$(getSHA256 "9944822${XClaim}8${XClaim}113")

hanime_email=${HTV_EMAIL:-"$1"}
hanime_password=${HTV_PASSWORD:-"$2"}


if [ -z "$hanime_email" ] || [ -z "$hanime_password" ]; then
    echo "[!] Please provide your hanime email and password as arguments or set env vars for 'HTV_EMAIL' and 'HTV_PASSWORD' since '$session_file' is missing."
    exit 1
fi

login() {
    local email="$1"
    local password="$2"
    headers=(-H "Content-Type: application/json" -H "X-Signature-Version: app2" -H "X-Claim: ${XClaim}" -H "X-Signature: ${XSig}")
    local response=$(curl -s -X POST "${host}/rapi/v4/sessions" "${headers[@]}" -d "{\"burger\":\"${email}\",\"fries\":\"${password}\"}")
    local session_token=$(echo $response | jq -r .session_token)
    echo $session_token | openssl enc -e -des3 -base64 -pass pass:$hanime_password -pbkdf2 > $session_file
    echo $response
}

get_info() {
    local session_token="$1"
    local headers=(-H "Content-Type: application/json" -H "X-Signature-Version: app2" -H "X-Claim: ${XClaim}" -H "X-Signature: ${XSig}" -H "X-Session-Token:${session_token}")
    local response=$(curl -s -X GET "${host}/rapi/v4/home" "${headers[@]}")
    echo $response
}

get_coins() {
    local session_token="$1"
    local version="$2"
    local uid="$3"
    local curr_time=$(date +%s)
    local to_hash="coins${version}|${uid}|${curr_time}|coins${version}"
    local reward_token=$(getSHA256 "${to_hash}")
    local headers=(-H "Content-Type: application/json" -H "X-Signature-Version: app2" -H "X-Claim: ${XClaim}" -H "X-Signature: ${XSig}" -H "X-Session-Token: ${session_token}")
    local response=$(curl -s -X POST "${host}/rapi/v4/coins" "${headers[@]}" -d "{\"reward_token\":\"${reward_token}|${curr_time}\",\"version\":\"${version}\"}")
    if [[ "${response}" == *"Unauthorized"* ]]; then
        echo "[!] Something went wrong. Most probably you have already collected your coins."
        exit 1
    fi
    echo "You received $(echo "${response}" | jq -r '.rewarded_amount') coins."
}

main() {
    if [ -s "$session_file" ]; then
        echo "[#] Session file found. The credintials will be ignored."
        local session_token="$(cat $session_file | openssl enc -d -des3 -base64 -pass pass:$hanime_password -pbkdf2 2>&1)"
        if [[ $session_token = bad* ]]; then
            echo "[!] Incorrect password for decrypting the session file"
            exit 1
        fi

        local info=$(get_info "${session_token}")
        if [[ "${info}" == *"Unauthorized"* ]]; then
            echo "[#] Unable to make the request to fetch user info, Retrying by refreshing the session token."
            local info=$(login "${hanime_email}" "${hanime_password}")
            if [[ "${info}" == *"Unauthorized"* ]]; then
                echo "[!] Unable to make the login to your account, Please try again later."
                exit 1
            fi
            local session_token=$(echo $info | jq -r .session_token)
        fi
    else 
        echo "[#] '$session_file' does not exist."
        echo "[#] Requesting new session by logging in via provided credintials."
        echo "Provided Email: ${hanime_email}"
        echo "Provided Password: ${hanime_password}"
        local info=$(login "${hanime_email}" "${hanime_password}")
        if [[ "${info}" == *"Unauthorized"* ]]; then
            echo "[!] Unable to make the login to your account, Please try again later."
            exit 1
        fi
        local session_token=$(echo "${info}" | jq -r .session_token)
    fi


    local uid=$(echo "${info}" | jq -r .user.id)
    local name=$(echo "${info}" | jq -r .user.name)
    local coins=$(echo "${info}" | jq -r .user.coins)
    local last_click_date=$(echo "${info}" | jq -r .user.last_rewarded_ad_clicked_at)
    local version=$(echo "${info}" | jq -r .env.mobile_apps._build_number)
    echo "[*] Logged in as ${name} [$uid]"
    echo "[*] Coins count: ${coins}"
    echo "[*] Last coins claimed on: ${last_click_date}"
    echo "[*] App version: ${version}"
    current_time=$(date '+%s')
    if [[ $last_click_date ]]; then
        predicted_time=$(date_epoch_offset "$last_click_date" 10800)   # +3 hours
        if [[ "$current_time" > $predicted_time ]]; then
            get_coins $session_token $version $uid
        else
            local next_time_readble=$(date -d @"$predicted_time" '+%F %T' 2>/dev/null || date -r "$predicted_time" '+%F %T' 2>/dev/null)
            echo "[!] You have to wait till ${next_time_readble} to collect anymore coins"
        fi
    else
        echo "[#] First time?"
        get_coins $session_token $version $uid
    fi
    
}

main