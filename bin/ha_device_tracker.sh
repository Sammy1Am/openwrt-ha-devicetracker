#!/bin/sh

# Source OpenWrt's UCI functions
. /lib/functions.sh

CONFIG_FILE="ha_device_tracker" # UCI will look in /etc/config/
LOG_TAG="ha_device_tracker"

# Global variables to store current event details for the UCI callback
CURRENT_EVENT_MAC=""
CURRENT_EVENT_TYPE=""

# Global variables for HA connection, populated from config
HA_URL=""
HA_TOKEN=""
DEBUG=0

# Function to log messages
log_message() {
    if [ "$DEBUG" -eq 1 ]; then
        logger -t "$LOG_TAG" "DEBUG: $1"
    elif [ "$1" != "${1#ERROR:}" ] || [ "$1" != "${1#WARNING:}" ]; then # Log errors and warnings even if debug is off
        logger -t "$LOG_TAG" "$1"
    fi
}

# Function to send update to Home Assistant using wget
send_to_home_assistant() {
    local mac_address="$1"
    local status="$2" # "home" or "not_home"
    local device_name="$3"
    local ha_url_api="${HA_URL}/api/services/device_tracker/see"
    local post_data

    post_data="{\"mac\": \"${mac_address}\", \"dev_id\": \"${device_name}\", \"location_name\": \"${status}\"}"

    log_message "Sending to HA (wget): URL: ${ha_url_api}, Data: ${post_data}"

    # Check for wget
    if ! command -v wget >/dev/null 2>&1; then
        log_message "ERROR: wget command not found. Please install wget (opkg install wget)."
        return 1
    fi
    # Check for jq
    if ! command -v jq >/dev/null 2>&1; then
        log_message "ERROR: jq command not found. Please install jq (opkg install jq)."
        return 1
    fi

    # wget for POST request
    # -q: quiet
    # -O /dev/null: discard output
    # --header: set headers
    # --post-data: send JSON data
    # --timeout: set a timeout (e.g., 5 seconds) to prevent indefinite hanging
    # --tries: number of retries (e.g., 1, meaning try once)
    wget -q -O /dev/null \
         --header="Authorization: Bearer ${HA_TOKEN}" \
         --header="Content-Type: application/json" \
         --post-data="${post_data}" \
         --timeout=5 \
         "${ha_url_api}"

    if [ $? -eq 0 ]; then
        log_message "Successfully sent update to Home Assistant for ${device_name} (${mac_address}) as ${status} using wget."
    else
        log_message "ERROR: Error sending update to Home Assistant for ${device_name} (${mac_address}) using wget. Exit code: $?. Check HA_URL, HA_TOKEN, and network."
    fi
}

# Function to process a single configured device against the current ubus event
# This function is called by `config_foreach`
# It accesses CURRENT_EVENT_MAC and CURRENT_EVENT_TYPE from the script's global scope.
process_configured_device_against_current_event() {
    local section_name="$1" # UCI section ID (e.g., cfg023a2)
    local device_enabled configured_mac configured_name

    config_get_bool device_enabled "$section_name" "enabled" 0 # Default to disabled (0) if 'enabled' option is missing
    config_get configured_mac "$section_name" "mac" ""
    config_get configured_name "$section_name" "name" ""

    if [ "$device_enabled" -eq 0 ] || [ -z "$configured_mac" ] || [ -z "$configured_name" ]; then
        log_message "Skipping device in section $section_name: Disabled, or MAC/Name not set."
        return
    fi

    local configured_mac_lower=$(echo "$configured_mac" | awk '{print tolower($0)}')

    log_message "Checking event for configured device: Name: $configured_name, MAC: $configured_mac_lower. Event MAC: $CURRENT_EVENT_MAC"

    if [ "$CURRENT_EVENT_MAC" = "$configured_mac_lower" ]; then
        log_message "MATCH: Event MAC $CURRENT_EVENT_MAC matches $configured_name ($configured_mac_lower)."
        if [ "$CURRENT_EVENT_TYPE" = "assoc" ]; then
            log_message "Device $configured_name ($configured_mac_lower) associated."
            send_to_home_assistant "$configured_mac_lower" "home" "$configured_name"
        elif [ "$CURRENT_EVENT_TYPE" = "disassoc" ]; then
            log_message "Device $configured_name ($configured_mac_lower) disassociated."
            send_to_home_assistant "$configured_mac_lower" "not_home" "$configured_name"
        else
            log_message "Ignoring event type: $CURRENT_EVENT_TYPE for matched MAC: $configured_mac_lower ($configured_name)"
        fi
    fi
}

# --- Main Script ---

# Load UCI configuration for the 'home_assistant_tracker' package
config_load "$CONFIG_FILE"

# Read global settings
config_get_bool global_enabled "settings" "enabled" 0
config_get HA_URL "settings" "ha_url" ""
config_get HA_TOKEN "settings" "ha_token" ""
config_get hostapd_ifaces "settings" "hostapd_ifaces" ""
config_get_bool DEBUG "settings" "debug" 0


if [ "$global_enabled" -ne 1 ]; then
    log_message "Tracker is globally disabled in the configuration. Exiting."
    exit 0
fi

if [ -z "$HA_URL" ] || [ -z "$HA_TOKEN" ] || [ -z "$hostapd_ifaces" ]; then
    log_message "ERROR: HA_URL, HA_TOKEN, or hostapd_ifaces not set in global settings. Exiting."
    exit 1
fi

log_message "Tracker started. Monitoring hostapd interfaces: $hostapd_ifaces. HA URL: $HA_URL. Debug: $DEBUG"
log_message "Ensure 'jshn' and 'curl' packages are installed."

# Subscribe to ubus events
# The -S option might not be available or behave the same on all OpenWrt versions for simplified output.
# If raw JSON is too verbose or causes issues, 'ubus listen' without -S and more robust json parsing might be needed.
ubus -S subscribe ${hostapd_ifaces} | while read -r event_line; do
    log_message "Raw ubus event line: $event_line"

    # Extract the event type (the first key of the JSON object, e.g., "assoc" or "disassoc")
    event_key=$(echo "$event_line" | jq -r 'keys_unsorted[0]' 2>/dev/null)

    if [ -z "$event_key" ]; then
        log_message "Could not parse event key (e.g., assoc/disassoc) from: $event_line"
        continue
    fi

    # Validate if the event_key is one we care about before proceeding
    if [ "$event_key" != "assoc" ] && [ "$event_key" != "disassoc" ]; then
        log_message "Ignoring event with key: $event_key"
        continue
    fi

    CURRENT_EVENT_TYPE="$event_key" # Should be "assoc" or "disassoc" (without quotes)

    # Extract MAC address using the dynamic event_key: .[$event_key].address
    # We use --arg to pass the shell variable event_key to jq
    mac_address_from_event=$(echo "$event_line" | jq -r --arg ek "$CURRENT_EVENT_TYPE" '.[$ek].address // empty' 2>/dev/null)
    # ' // empty ' will output nothing if the path is not found, preventing "null" string

    # Convert to lowercase (awk handles null input gracefully, resulting in an empty string)
    mac_address_from_event=$(echo "$mac_address_from_event" | awk '{print tolower($0)}')

    if [ -n "$mac_address_from_event" ]; then
        CURRENT_EVENT_MAC="$mac_address_from_event"
        log_message "Processed Event: Type: $CURRENT_EVENT_TYPE, MAC: $CURRENT_EVENT_MAC. Checking against configured devices."
        config_foreach process_configured_device_against_current_event device
    else
        log_message "No MAC address extracted using key '$CURRENT_EVENT_TYPE' from event data: $event_line"
    fi
done