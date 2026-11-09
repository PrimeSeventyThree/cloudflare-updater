#!/usr/bin/env bash

# File: cloudflare-dns-update.sh
# Description: Updates a Cloudflare DNS A record with the public IP address of the machine.
# Useful for maintaining a dynamic DNS setup.

# Author: Andrei Grichine (andrei.grichine@gmail.com)
# Created: Wednesday, 16th October 2024 6:41:31 PM
# Last Modified: Monday, 9th November 2026

# License: MIT License (see LICENSE file in the project root for full license)

# ------------------------------------------------------------------------------
# This script updates a Cloudflare DNS A record with the public IP address of the
# machine it's run on. It's useful for maintaining a dynamic DNS setup, ensuring
# that your domain always points to your current IP address, even if it changes.
# ------------------------------------------------------------------------------

# HISTORY:
# - Initial creation of the script.
# - Added error handling and logging.
# - Integrated notification support via Slack and Discord.
# - 2026-11-09: skip gcloud and the Cloudflare API while the public IP is unchanged (rechecked hourly), several
#   records per run, a lock against overlapping runs.


# Exit immediately if a command exits with a non-zero status,
# treat unset variables as errors, and fail on any command in a pipeline.
set -euo pipefail

###########################################
# Color Definitions
###########################################

# Check if the terminal supports colors
if [[ -t 1 ]] && tput colors &>/dev/null && [[ $(tput colors) -ge 8 ]]; then
  RED=$(tput setaf 1)
  GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4)
  MAGENTA=$(tput setaf 5)
  CYAN=$(tput setaf 6)
  BOLD=$(tput bold)
  RESET=$(tput sgr0)
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  MAGENTA=""
  CYAN=""
  BOLD=""
  RESET=""
fi

###########################################
# Constants and Default Values
###########################################

# Default configuration file path
DEFAULT_CONFIG_FILE="$HOME/.cloudflare-config.env"

# Default: no GCP firewall rules to sync (override as an array in the config file)
declare -a GCP_FIREWALL_RULES=()

###########################################
# Functions
###########################################

print_help() {
  cat <<EOF
${BOLD}${CYAN}Cloudflare Dynamic DNS Update Script${RESET}
${CYAN}------------------------------------${RESET}

This script updates a Cloudflare DNS A record with the public IP address of the machine it's run on.
It's useful for maintaining a dynamic DNS setup.

${BOLD}Usage:${RESET}
  $0 [options] [domain ...]

${BOLD}Options:${RESET}
  -h, --help        Show this help message and exit.

${BOLD}Arguments:${RESET}
  domain ...        (Optional) One or more DNS records to update. If not provided, the script will use CF_RECORD_NAME or DEFAULT_DOMAIN from the configuration file.

${BOLD}Configuration:${RESET}
  The script requires a configuration file to set up necessary environment variables.
  By default, it looks for the configuration file at:

    ${YELLOW}$DEFAULT_CONFIG_FILE${RESET}

  You can override the configuration file path by setting the CONFIG_FILE environment variable before running the script:

    ${YELLOW}CONFIG_FILE="/path/to/your_config.env" $0${RESET}

${BOLD}Required variables in the configuration file:${RESET}

  ${CYAN}CF_AUTH_EMAIL${RESET}     Your Cloudflare account email. Required if using Global API Key.
  ${CYAN}CF_AUTH_KEY${RESET}       Your Cloudflare API Token or Global API Key.
  ${CYAN}CF_ZONE_ID${RESET}        The Zone ID of your domain in Cloudflare.
  ${CYAN}CF_AUTH_METHOD${RESET}    Authentication method: "token" for API Token, "global" for Global API Key.

${BOLD}Optional variables in the configuration file:${RESET}

  ${CYAN}CF_RECORD_NAME${RESET}    The DNS record name to update if not provided as an argument.
  ${CYAN}DEFAULT_DOMAIN${RESET}    Fallback DNS record name if CF_RECORD_NAME is not set.
  ${CYAN}CF_TTL${RESET}            DNS TTL in seconds. Default is 3600.
  ${CYAN}CF_PROXY${RESET}          Whether the record is proxied through Cloudflare (true or false). Default is false.
  ${CYAN}SITE_NAME${RESET}         A name for your site, used in notifications.
  ${CYAN}SLACK_CHANNEL${RESET}     Slack channel for notifications.
  ${CYAN}SLACK_URI${RESET}         Slack Webhook URL for notifications.
  ${CYAN}DISCORD_URI${RESET}       Discord Webhook URL for notifications.
  ${CYAN}GCP_FIREWALL_RULES${RESET}  Bash array of "project:rule-name" pairs. For each entry, the
                       rule's --source-ranges is synced to the current public IP (/32),
                       replacing whatever was there before. Requires the gcloud CLI to be
                       installed and authenticated with permission to update the rule.

${BOLD}Example Configuration File:${RESET}

  ${YELLOW}# $DEFAULT_CONFIG_FILE${RESET}

  export CF_AUTH_EMAIL="your-email@example.com"
  export CF_AUTH_KEY="your_api_token_or_global_key"
  export CF_ZONE_ID="your_zone_id"
  export CF_AUTH_METHOD="token"

  # Optional variables
  export CF_RECORD_NAME="your.domain.com"
  export DEFAULT_DOMAIN="default.domain.com"
  export CF_TTL=3600
  export CF_PROXY=false
  export SITE_NAME="My Site"
  export SLACK_CHANNEL="#notifications"
  export SLACK_URI="https://hooks.slack.com/services/your/slack/webhook"
  export DISCORD_URI="https://discordapp.com/api/webhooks/your/discord/webhook"
  export GCP_FIREWALL_RULES=("your-gcp-project:your-firewall-rule-name")

${BOLD}Instructions:${RESET}

1. Create the configuration file with the required variables.
2. Ensure the configuration file has appropriate permissions:

   ${YELLOW}chmod 600 $DEFAULT_CONFIG_FILE${RESET}

3. Run the script:

   ${YELLOW}$0${RESET}

   Or specify the domain as an argument:

   ${YELLOW}$0 your.domain.com${RESET}

4. (Optional) Set up notifications by configuring Slack or Discord webhook URLs in the configuration file.

EOF
}

log_error() {
  echo -e "${RED}Error:${RESET} $1" >&2
}

log_info() {
  echo -e "${GREEN}Info:${RESET} $1"
}

get_public_ip() {
  local ip
  ip=$(curl -s -4 https://cloudflare.com/cdn-cgi/trace | grep -E '^ip=' | cut -d'=' -f2) || true
  if [[ -z "$ip" ]]; then
    ip=$(curl -s https://api.ipify.org) || true
  fi
  if [[ -z "$ip" ]]; then
    ip=$(curl -s https://ipv4.icanhazip.com) || true
  fi
  echo "$ip"
}

validate_ip() {
  local ip="$1"
  if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    log_error "Invalid IP address '$ip'."
    exit 1
  fi
}

fetch_dns_record() {
  local response
  response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=A&name=$record_name" \
    "${auth_headers[@]}" \
    -H "Content-Type: application/json")

  # Check if the response is valid JSON
  if ! echo "$response" | jq . >/dev/null 2>&1; then
    log_error "Invalid JSON response from Cloudflare API."
    log_error "Response: $response"
    exit 1
  fi

  echo "$response"
}

update_dns_record() {
  local record_id="$1"
  local ip="$2"
  local update_data
  update_data=$(jq -n \
    --arg type "A" \
    --arg name "$record_name" \
    --arg content "$ip" \
    --argjson ttl "$CF_TTL" \
    --argjson proxied "$CF_PROXY" \
    '{type: $type, name: $name, content: $content, ttl: $ttl, proxied: $proxied}')

  local response
  response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$record_id" \
    "${auth_headers[@]}" \
    -H "Content-Type: application/json" \
    --data "$update_data")

  # Check if the response is valid JSON
  if ! echo "$response" | jq . >/dev/null 2>&1; then
    log_error "Invalid JSON response from Cloudflare API during update."
    log_error "Response: $response"
    exit 1
  fi

  echo "$response"
}

send_notification() {
  local message="$1"
  if [[ -n "${SLACK_URI:-}" ]]; then
    curl -s -X POST "$SLACK_URI" \
      -H "Content-Type: application/json" \
      --data-raw '{
        "channel": "'"${SLACK_CHANNEL:-""}"'",
        "text": "'"$message"'"
      }' >/dev/null || true
  fi
  if [[ -n "${DISCORD_URI:-}" ]]; then
    curl -s -X POST "$DISCORD_URI" \
      -H "Content-Type: application/json" \
      --data-raw '{
        "content": "'"$message"'"
      }' >/dev/null || true
  fi
}

update_gcp_firewall_rules() {
  local ip="$1"
  local cidr="${ip}/32"
  local failures=0

  if [[ ${#GCP_FIREWALL_RULES[@]} -eq 0 ]]; then
    return 0
  fi

  if ! command -v gcloud >/dev/null 2>&1; then
    log_error "gcloud is not installed; skipping GCP firewall rule updates."
    return 1
  fi

  local entry project rule current_ranges err
  for entry in "${GCP_FIREWALL_RULES[@]}"; do
    project="${entry%%:*}"
    rule="${entry#*:}"

    if [[ -z "$project" || -z "$rule" || "$project" == "$entry" ]]; then
      log_error "Invalid GCP_FIREWALL_RULES entry '$entry'. Expected format 'project:rule-name'."
      failures=$((failures + 1))
      continue
    fi

    if ! current_ranges=$(gcloud compute firewall-rules describe "$rule" \
      --project "$project" \
      --format="value(sourceRanges)" 2>&1); then
      log_error "Failed to read firewall rule '$rule' in project '$project': $current_ranges"
      failures=$((failures + 1))
      continue
    fi

    if [[ "$current_ranges" == "$cidr" ]]; then
      log_info "Firewall rule '$rule' in '$project' already allows $cidr."
      continue
    fi

    if err=$(gcloud compute firewall-rules update "$rule" \
      --project "$project" \
      --source-ranges "$cidr" 2>&1); then
      log_info "Firewall rule '$rule' in '$project' updated: ${current_ranges:-none} -> $cidr"
    else
      log_error "Failed to update firewall rule '$rule' in project '$project': $err"
      failures=$((failures + 1))
    fi
  done
  [[ $failures -eq 0 ]]
}

###########################################
# Main Script
###########################################

# Check for help option
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_help
  exit 0
fi

# Define the configuration file path
CONFIG_FILE="${CONFIG_FILE:-$DEFAULT_CONFIG_FILE}"

# Check if the configuration file exists and is readable
if [[ ! -r "$CONFIG_FILE" ]]; then
  log_error "Configuration file '$CONFIG_FILE' not found or not readable."
  print_help
  exit 1
fi

# Source the configuration file
# shellcheck disable=SC1090
source "$CONFIG_FILE"

###########################################
# Verify Required Variables
###########################################

: "${CF_AUTH_EMAIL:?$(log_error "CF_AUTH_EMAIL is not set in the configuration file"); exit 1}"
: "${CF_AUTH_KEY:?$(log_error "CF_AUTH_KEY is not set in the configuration file"); exit 1}"
: "${CF_ZONE_ID:?$(log_error "CF_ZONE_ID is not set in the configuration file"); exit 1}"
: "${CF_AUTH_METHOD:=token}"
: "${CF_TTL:=3600}"
: "${CF_PROXY:=false}"

###########################################
# Check Dependencies
###########################################

# Required commands
required_commands=(curl jq)

for cmd in "${required_commands[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "$cmd is not installed. Please install it."
    exit 1
  fi
done

###########################################
# Handle Command-Line Arguments
###########################################

# One or more DNS records per run. The public IP lookup and the GCP firewall check are shared, so list every record
# in one cron line rather than one cron line per record.
if [[ $# -ge 1 ]]; then
  record_names=("$@")
elif [[ -n "${CF_RECORD_NAME:-}" ]]; then
  record_names=("$CF_RECORD_NAME")
elif [[ -n "${DEFAULT_DOMAIN:-}" ]]; then
  record_names=("$DEFAULT_DOMAIN")
else
  log_error "No domain name provided. Use a command-line argument, or set CF_RECORD_NAME or DEFAULT_DOMAIN."
  print_help
  exit 1
fi

###########################################
# Validate Domain Names
###########################################

for record_name in "${record_names[@]}"; do
  if ! [[ "$record_name" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; then
    log_error "Invalid domain name '$record_name'."
    exit 1
  fi
done

###########################################
# Set Authentication Headers
###########################################

declare -a auth_headers

if [[ "$CF_AUTH_METHOD" == "global" ]]; then
  auth_headers=(
    -H "X-Auth-Email: $CF_AUTH_EMAIL"
    -H "X-Auth-Key: $CF_AUTH_KEY"
  )
elif [[ "$CF_AUTH_METHOD" == "token" ]]; then
  auth_headers=(-H "Authorization: Bearer $CF_AUTH_KEY")
else
  log_error "Invalid CF_AUTH_METHOD '$CF_AUTH_METHOD'. Use 'global' or 'token'."
  exit 1
fi

###########################################
# State: last confirmed IP per target, and a lock
###########################################

# Each target (the GCP firewall rules, each DNS record) remembers the IP it was last confirmed at. While the public
# IP stays the same, the script skips gcloud and the Cloudflare API. It rechecks them anyway once the confirmation
# is CF_RECHECK_SECONDS old (default 3600), so a change made elsewhere (console, another host) is corrected.
STATE_DIR="${CF_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cloudflare-ddns}"
: "${CF_RECHECK_SECONDS:=3600}"
mkdir -p "$STATE_DIR"

# One run at a time: a slow gcloud call must not let runs pile up behind it. Uses flock where it exists (Linux);
# without it (macOS) runs aren't serialised, which only matters when a run takes longer than the cron interval.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$STATE_DIR/lock"
  if ! flock -n 9; then
    log_info "Another run is in progress; skipping."
    exit 0
  fi
fi

# mtime FILE: modification time in epoch seconds (GNU stat, then BSD/macOS stat).
mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

# is_current TARGET IP: true when TARGET was confirmed at IP less than CF_RECHECK_SECONDS ago.
is_current() {
  local file="$STATE_DIR/$1.ip" age
  [[ -f "$file" && "$(cat "$file")" == "$2" ]] || return 1
  age=$(( $(date +%s) - $(mtime "$file") ))
  (( age < CF_RECHECK_SECONDS ))
}

# mark_current TARGET IP
mark_current() {
  printf '%s\n' "$2" > "$STATE_DIR/$1.ip"
}

###########################################
# Get Public IP
###########################################

ip=$(get_public_ip)
if [[ -z "$ip" ]]; then
  log_error "Unable to obtain public IP address."
  exit 1
fi

validate_ip "$ip"

###########################################
# Sync GCP Firewall Rules (optional)
###########################################

gcp_status=0
if [[ ${#GCP_FIREWALL_RULES[@]} -gt 0 ]]; then
  # The state key includes the rule list, so editing GCP_FIREWALL_RULES forces a fresh check.
  gcp_key="gcp-$(printf '%s\n' "${GCP_FIREWALL_RULES[@]}" | cksum | cut -d" " -f1)"
  if is_current "$gcp_key" "$ip"; then
    log_info "GCP firewall rules already confirmed for $ip; gcloud skipped."
  elif update_gcp_firewall_rules "$ip"; then
    mark_current "$gcp_key" "$ip"
  else
    gcp_status=1
  fi
fi

###########################################
# Sync DNS Records
###########################################

# sync_record: brings the A record "$record_name" to "$ip". Returns non-zero on failure, so one failing record
# doesn't stop the others. (errexit is off inside a function called from "||", so every step is checked here.)
sync_record() {
  local record_response record_count record_identifier old_ip update_response message

  if is_current "dns-$record_name" "$ip"; then
    log_info "$record_name already confirmed at $ip; Cloudflare skipped."
    return 0
  fi

  if ! record_response=$(fetch_dns_record) ||
     [[ "$(echo "$record_response" | jq -r '.success')" != "true" ]]; then
    log_error "Failed to fetch DNS records for '$record_name'."
    log_error "Response: $record_response"
    return 1
  fi

  record_count=$(echo "$record_response" | jq '.result | length')
  if [[ "$record_count" -eq 0 ]]; then
    log_error "DNS record for '$record_name' does not exist."
    return 1
  fi

  record_identifier=$(echo "$record_response" | jq -r '.result[0].id')
  old_ip=$(echo "$record_response" | jq -r '.result[0].content')

  if [[ "$ip" == "$old_ip" ]]; then
    log_info "IP address has not changed for $record_name. Current IP is $ip."
    mark_current "dns-$record_name" "$ip"
    return 0
  fi

  if update_response=$(update_dns_record "$record_identifier" "$ip") &&
     [[ "$(echo "$update_response" | jq -r '.success')" == "true" ]]; then
    log_info "DNS record updated to $ip for $record_name."
    mark_current "dns-$record_name" "$ip"
    message="${SITE_NAME:-Site} Updated: $record_name new IP Address is $ip"
    send_notification "$message"
    return 0
  fi

  log_error "Failed to update DNS record for '$record_name'."
  log_error "Response: ${update_response:-}"
  message="${SITE_NAME:-Site} DDNS Update Failed: $record_name ($ip)"
  send_notification "$message"
  return 1
}

rc=$gcp_status
for record_name in "${record_names[@]}"; do
  sync_record || rc=1
done
exit "$rc"
