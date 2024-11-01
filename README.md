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
- [Security Considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## Features

- Updates a Cloudflare DNS A record with the current public IP address.
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

Ensure that these dependencies are installed on your system:

```bash
# For Debian/Ubuntu
sudo apt-get install curl jq

# For CentOS/RHEL
sudo yum install curl jq
```
## Installation
Clone the Repository:

```bash
git clone https://github.com/yourusername/cloudflare-dns-update-script.git
cd cloudflare-dns-update-script
```
Make the Script Executable:

```bash
chmod +x cloudflare-dns-update.sh
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

  - Redirect output to a log file to capture any errors:

```bash
*/5 * * * * /path/to/cloudflare-dns-update.sh >> /path/to/cloudflare-dns-update.log 2>&1
```
## Contributing
Contributions are welcome! If you have suggestions for improvements or encounter any issues, please open an issue or submit a pull request on GitHub.

## License
This project is licensed under the MIT License.

