# Dynamic Cloudflare DNS Update Script

This script updates a Cloudflare DNS A record with the public IP address of the machine it's run on. It's useful for maintaining a dynamic DNS setup, ensuring that your domain always points to your current IP address, even if it changes.

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
  - [Create the Configuration File](#create-the-configuration-file)
  - [Secure the Configuration File](#secure-the-configuration-file)
- [Usage](#usage)
  - [Options](#options)
- [Examples](#examples)
- [Notifications](#notifications)
  - [Slack Notification](#slack-notification)
  - [Discord Notification](#discord-notification)
- [GCP Firewall Rule Sync](#gcp-firewall-rule-sync)
- [Skipping Unchanged IPs](#skipping-unchanged-ips)
- [Running from Cron](#running-from-cron)
- [Security Considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## Features

- Updates one or more Cloudflare DNS A records with the current public IP address.
- Remembers the last confirmed IP, so runs where nothing changed make no Cloudflare or `gcloud` calls (rechecked hourly).
- Supports both Global API Key and API Token authentication methods.
- Validates domain names and IP addresses.
- Provides detailed error handling and informative messages.
- Includes a comprehensive help function.
- Sends optional notifications via Slack and Discord when the IP address changes.
- Uses a configuration file for sensitive information, enhancing security.
- Colorized output for improved readability in supported terminals.

## Prerequisites

- **Operating System**: Linux, macOS, or any Unix-like system.
- **Shell**: Bash
- **Dependencies**:
  - `curl`
  - `jq`
  - `flock` (optional, part of util-linux on Linux): keeps runs from overlapping. Without it (macOS) the script still works, but runs aren't serialised.

Ensure that these dependencies are installed on your system:

```bash
# For Debian/Ubuntu
sudo apt-get install curl jq

# For CentOS/RHEL
sudo yum install curl jq
```
## Installation
### Option 1: Clone the Repository:

```bash
git clone https://github.com/yourusername/cloudflare-dns-update-script.git
cd cloudflare-dns-update-script
```
Make the Script Executable:

```bash
chmod +x cloudflare-dns-update.sh
```
### Option 2: Single-Line Installation
Use a single command to download and install the script into /usr/local/bin:
```bash
sudo -v && curl -sSL \
  https://github.com/PrimeSeventyThree/cloudflare-updater/raw/refs/heads/main/cloudflare-dns-update.sh \
  | sudo tee /usr/local/bin/cloudflare-dns-update.sh >/dev/null \
  && sudo chmod +x /usr/local/bin/cloudflare-dns-update.sh
```
## Configuration
Create the Configuration File
The script requires a configuration file to set up necessary environment variables. By default, it looks for the configuration file at `~/.cloudflare-config.env`.

Create the configuration file in your home directory:

```bash
nano ~/.cloudflare-config.env
```
Add the following content to the file:

```bash
# ~/.cloudflare-config.env

# Required variables
export CF_AUTH_EMAIL="your-email@example.com"    # Required if using Global API Key
export CF_AUTH_KEY="your_api_token_or_global_key"
export CF_ZONE_ID="your_zone_id"
export CF_AUTH_METHOD="token"                    # "token" for API Token, "global" for Global API Key

# Optional variables
export CF_RECORD_NAME="your.domain.com"          # If not providing as an argument
export DEFAULT_DOMAIN="default.domain.com"       # Fallback domain if no argument or CF_RECORD_NAME
export CF_TTL=3600                               # DNS TTL (seconds)
export CF_PROXY=false                            # true or false
export SITE_NAME="My Site"                       # For notifications
export SLACK_CHANNEL="#notifications"            # Slack channel name
export SLACK_URI="https://hooks.slack.com/services/your/slack/webhook"
export DISCORD_URI="https://discord.com/api/webhooks/your/discord/webhook"

# Optional: keep GCP VPC firewall rules pointed at your current IP
export GCP_FIREWALL_RULES=("your-gcp-project:your-firewall-rule-name")
```
Replace the placeholder values with your actual information.

## Secure the Configuration File
Set the appropriate permissions to protect your sensitive information:

```bash
chmod 600 ~/.cloudflare-config.env
```
## Usage
Run the script with or without arguments:

- Without Arguments: Uses `CF_RECORD_NAME` or `DEFAULT_DOMAIN` from the configuration file.

```bash
./cloudflare-dns-update.sh
```
- With Domain Argument: Overrides the domain specified in the configuration file.

```bash
./cloudflare-dns-update.sh your.domain.com
```
- With several domains: updates each record in one run. The public IP lookup and the GCP firewall check happen once. A failure on one record doesn't stop the others, and the exit status is non-zero if any failed.

```bash
./cloudflare-dns-update.sh your.domain.com other.domain.com
```
### Options
- `-h`, `--help`: Display the help message.

```bash
./cloudflare-dns-update.sh -h
```
## Examples
- Update DNS Record for a Specific Domain:

```bash
./cloudflare-dns-update.sh example.com
```
- Use a Different Configuration File:

```bash
CONFIG_FILE="/path/to/your_config.env" ./cloudflare-dns-update.sh
```
## Notifications
### Slack Notification
To receive Slack notifications when the IP address changes:

1. Set Up a Slack Webhook:

- Go to your Slack workspace and create an incoming webhook for the desired channel.
2. Update Configuration:

```bash
export SLACK_CHANNEL="#your-channel"
export SLACK_URI="https://hooks.slack.com/services/your/slack/webhook"
```
### Discord Notification
To receive Discord notifications:

1. Create a Discord Webhook:

- In your Discord server, create a webhook for the channel where you want to receive notifications.
2. Update Configuration:

```bash
export DISCORD_URI="https://discord.com/api/webhooks/your/discord/webhook"
```
## GCP Firewall Rule Sync
In addition to updating DNS, the script can keep one or more GCP VPC firewall rules restricted to your current public IP — replacing `--source-ranges` with `<ip>/32`, the same way you'd run:

```bash
gcloud compute firewall-rules update vless-reality-01-allow-ssh \
  --project [PROJECT_ID] \
  --source-ranges [IP_ADDRESS]/32
```

This is disabled unless you set `GCP_FIREWALL_RULES` in your configuration file, as a Bash array of `"project:rule-name"` pairs:

```bash
export GCP_FIREWALL_RULES=("[PROJECT_ID]:[FIREWALL_RULE_ID]")

# Multiple rules and/or projects are supported:
export GCP_FIREWALL_RULES=(
  "[PROJECT_ID]:[FIREWALL_RULE_ID]"
  "another-project:another-rule"
)
```

Notes:
- GCP firewall rules are project-scoped, not zone-scoped — there's no `--zone` flag on `gcloud compute firewall-rules update`, so only project + rule name are needed.
- The rule's current `sourceRanges` is checked first; if it already matches `<ip>/32`, no API call is made.
- Requires the [`gcloud` CLI](https://cloud.google.com/sdk/docs/install) to be installed and already authenticated (e.g. `gcloud auth login` or a service account) with permission to update the rule (`compute.firewalls.update`).
- This check runs independently of the Cloudflare DNS comparison, so it self-corrects even if a previous run updated DNS but failed to update the firewall rule.
- `gcloud` is slow to start (often several seconds of CPU per call, about a minute on older hardware). The script calls it only when the public IP changes or the hourly recheck is due (see [Skipping Unchanged IPs](#skipping-unchanged-ips)).
- For cron use, turn off gcloud's usage reporting. Otherwise each call also starts a `metrics_reporter.py` process:

```bash
gcloud config set disable_usage_reporting true
```

## Skipping Unchanged IPs
Each target (the set of GCP firewall rules, and each DNS record) remembers the IP it was last confirmed at, in a small state file. While the public IP stays the same, a run only looks up the public IP and exits. It makes no Cloudflare API calls and starts no `gcloud`.

Each target is checked against the real record again once its confirmation is older than `CF_RECHECK_SECONDS`, so a change made elsewhere (in the Cloudflare dashboard, the GCP console or from another host) is corrected. Changing `GCP_FIREWALL_RULES` forces a fresh firewall check.

Optional settings (environment or configuration file):

| Variable | Default | Meaning |
|---|---|---|
| `CF_RECHECK_SECONDS` | `3600` | Maximum age of a confirmation before the target is checked again |
| `CF_STATE_DIR` | `${XDG_STATE_HOME:-~/.local/state}/cloudflare-ddns` | Where the state files and the lock live |

To force a full check on the next run, delete the state files: `rm ~/.local/state/cloudflare-ddns/*.ip`.

## Running from Cron
Run every record from one cron line, so the IP lookup and the firewall check are shared:

```bash
* * * * * /path/to/cloudflare-dns-update.sh your.domain.com other.domain.com >/dev/null || echo "cloudflare-dns-update failed" >&2
```

Running every minute is cheap now: an unchanged run is one HTTPS request. With `flock` installed, a run that starts while another is still busy exits straight away.

## Security Considerations
- Protect Your API Keys:

  - Ensure that your configuration file is not accessible by unauthorized users.
  - Do not commit the configuration file to version control systems.
- File Permissions:

  - The configuration file should have permissions set to `600`.

```bash
chmod 600 ~/.cloudflare-config.env
```
## Troubleshooting
- Missing Dependencies:

  - If you receive errors about missing `curl` or `jq`, install them using your package manager.
- Invalid JSON Response:

  - If the script reports an invalid JSON response from the Cloudflare API, check your network connection and verify that your API credentials are correct.
- Configuration File Not Found:

  - Ensure that the configuration file exists at ~/.cloudflare-config.env or specify the correct path using the CONFIG_FILE environment variable.
- Permission Denied Errors:

  - If you encounter permission issues, ensure that the script has execute permissions:

```bash
chmod +x cloudflare-dns-update.sh
```
- Cron Job Issues:

  - When running the script via cron, make sure to use absolute paths for both the script and the configuration file.

  - Cron's `PATH` is short. If you use the GCP firewall sync, add the `gcloud` directory to `PATH` in the crontab.

  - Redirect output to a log file to capture any errors:

```bash
*/5 * * * * /path/to/cloudflare-dns-update.sh >> /path/to/cloudflare-dns-update.log 2>&1
```
## Contributing
Contributions are welcome! If you have suggestions for improvements or encounter any issues, please open an issue or submit a pull request on GitHub.

## License
This project is licensed under the MIT License.

