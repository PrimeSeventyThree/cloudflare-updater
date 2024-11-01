#!/usr/bin/env bash

# File: cloudflare-dns-update.sh
# Description: Updates a Cloudflare DNS A record with the public IP address of the machine.
# Useful for maintaining a dynamic DNS setup.

# Author: Andrei Grichine (andrei.grichine@gmail.com)
# Created: Wednesday, 16th October 2024 6:41:31 PM
# Last Modified: Friday, 1st November 2024 9:15:11 AM

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
  $0 [options] [domain]

${BOLD}Options:${RESET}
  -h, --help        Show this help message and exit.

${BOLD}Arguments:${RESET}
  domain            (Optional) The DNS record to update. If not provided, the script will use CF_RECORD_NAME or DEFAULT_DOMAIN from the configuration file.

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

if [[ $# -ge 1 ]]; then
  record_name="$1"
elif [[ -n "${CF_RECORD_NAME:-}" ]]; then
  record_name="$CF_RECORD_NAME"
elif [[ -n "${DEFAULT_DOMAIN:-}" ]]; then
  record_name="$DEFAULT_DOMAIN"
else
  log_error "No domain name provided. Use a command-line argument, or set CF_RECORD_NAME or DEFAULT_DOMAIN."
  print_help
  exit 1
fi

###########################################
# Validate Domain Name
###########################################

if ! [[ "$record_name" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; then
  log_error "Invalid domain name '$record_name'."
  exit 1
fi

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
# Get Public IP
###########################################

ip=$(get_public_ip)
if [[ -z "$ip" ]]; then
  log_error "Unable to obtain public IP address."
  exit 1
fi

validate_ip "$ip"

###########################################
# Fetch Existing DNS Record
###########################################

record_response=$(fetch_dns_record)

# Check if the request was successful
if [[ "$(echo "$record_response" | jq -r '.success')" != "true" ]]; then
  log_error "Failed to fetch DNS records."
  log_error "Response: $record_response"
  exit 1
fi

# Check if the record exists
record_count=$(echo "$record_response" | jq '.result | length')
if [[ "$record_count" -eq 0 ]]; then
  log_error "DNS record for '$record_name' does not exist."
  exit 1
fi

# Extract record ID and current IP
record_identifier=$(echo "$record_response" | jq -r '.result[0].id')
old_ip=$(echo "$record_response" | jq -r '.result[0].content')

###########################################
# Compare IP Addresses
###########################################

if [[ "$ip" == "$old_ip" ]]; then
  log_info "IP address has not changed. Current IP is $ip."
  exit 0
fi

###########################################
# Update DNS Record
###########################################

update_response=$(update_dns_record "$record_identifier" "$ip")

# Check if the update was successful
if [[ "$(echo "$update_response" | jq -r '.success')" == "true" ]]; then
  log_info "DNS record updated to $ip for $record_name."
  message="${SITE_NAME:-Site} Updated: $record_name new IP Address is $ip"
  send_notification "$message"
  exit 0
else
  log_error "Failed to update DNS record."
  log_error "Response: $update_response"
  message="${SITE_NAME:-Site} DDNS Update Failed: $record_name ($ip)"
  send_notification "$message"
  exit 1
fi
