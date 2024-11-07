#!/bin/bash

# Function to display messages
show() {
    echo "$1"
}

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    show "jq not found, installing..."
    sudo apt-get update
    sudo apt-get install -y jq > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        show "Failed to install jq. Please check your package manager."
        exit 1
    fi
fi

check_latest_version() {
    local REPO_URL="https://api.github.com/repos/block-mesh/block-mesh-monorepo/releases"
    
    show "Checking for the latest release with available binary file..."
    
    # Loop through releases to find one with a downloadable binary
    for page in {1..5}; do  # Adjust the page limit if needed
        RELEASES=$(curl -s "${REPO_URL}?page=$page&per_page=10")
        if [ $? -ne 0 ]; then
            show "curl failed. Please ensure curl is installed and working properly."
            exit 1
        fi
        
        # Get the number of releases on this page
        release_count=$(echo "$RELEASES" | jq '. | length')
        
        # Loop through each release and check for the binary file
        for i in $(seq 0 $((release_count-1))); do
            release=$(echo "$RELEASES" | jq -r ".[$i]")
            VERSION=$(echo "$release" | jq -r '.tag_name')
            ASSETS_URL=$(echo "$release" | jq -r '.assets_url')
            
            # Get assets for this release
            ASSETS=$(curl -s "$ASSETS_URL")
            BINARY_URL=$(echo "$ASSETS" | jq -r '.[] | select(.name | test("blockmesh-cli-x86_64-unknown-linux-gnu.tar.gz")) | .browser_download_url')
            
            if [ -n "$BINARY_URL" ]; then
                show "Found version with binary: $VERSION"
                DOWNLOAD_URL="$BINARY_URL"
                LATEST_VERSION="$VERSION"
                return 0  # Exit the function successfully
            fi
        done
    done
    
    # If no version is found after the loop
    show "No available version with binary file found."
    exit 1
}

# Call the function to get the latest available version with binary
check_latest_version

# Detect the architecture before downloading binaries
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    show "Unsupported architecture: $ARCH"
    exit 1
fi

# Create 'blockmesh' directory if it doesn't exist
BLOCKMESH_DIR="$HOME/blockmesh"
if [ ! -d "$BLOCKMESH_DIR" ]; then
    show "Creating directory: $BLOCKMESH_DIR"
    mkdir -p "$BLOCKMESH_DIR"
    if [ $? -ne 0 ]; then
        show "Failed to create directory $BLOCKMESH_DIR."
        exit 1
    fi
fi

# Check if the current version matches the latest version
CURRENT_VERSION=$(grep -oP '(?<=blockmesh_)[^/]*' "$BLOCKMESH_DIR/blockmesh-cli-x86_64-unknown-linux-gnu" 2>/dev/null)
if [ "$CURRENT_VERSION" != "$LATEST_VERSION" ]; then
    # If not up to date, download the latest version
    show "Downloading blockmesh-cli version $LATEST_VERSION..."
    curl -L "$DOWNLOAD_URL" -o "$BLOCKMESH_DIR/blockmesh-cli-x86_64-unknown-linux-gnu.tar.gz"
    if [ $? -ne 0 ]; then
        show "Failed to download file. Please check your internet connection."
        exit 1
    fi
    show "Downloaded: $BLOCKMESH_DIR/blockmesh-cli-x86_64-unknown-linux-gnu.tar.gz"
    # Extract the downloaded file into the 'blockmesh' folder
    show "Extracting file..."
    tar -xvzf "$BLOCKMESH_DIR/blockmesh-cli-x86_64-unknown-linux-gnu.tar.gz" -C "$BLOCKMESH_DIR" && rm "$BLOCKMESH_DIR/blockmesh-cli-x86_64-unknown-linux-gnu.tar.gz"
    if [ $? -ne 0 ]; then
        show "Failed to extract file."
        exit 1
    fi
    show "Extraction complete."
else
    show "You are already using the latest version: $LATEST_VERSION."
fi

# Set the service name
SERVICE_NAME="blockmesh"
# Reload systemd daemon before checking anything
sudo systemctl daemon-reload

# Check if the service exists
if systemctl status "$SERVICE_NAME" > /dev/null 2>&1; then
    # If the service exists, check if it's running
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        sudo systemctl stop "$SERVICE_NAME"
        sleep 5
    fi
    # Get existing email and password if available
    EMAIL=$(systemctl show "$SERVICE_NAME" -p Environment | awk -F'=' '/^Environment=EMAIL/ {print $2}')
    PASSWORD=$(systemctl show "$SERVICE_NAME" -p Environment | awk -F'=' '/^Environment=PASSWORD/ {print $2}')
    # Ask if the user wants to update the email or password
    read -p "Do you want to change your email? (yes/no): " change_email
    if [ "$change_email" == "yes" ]; then
        read -p "Enter your new email: " EMAIL
    fi
    read -s -p "Do you want to change your password? (yes/no): " change_password
    echo
    if [ "$change_password" == "yes" ]; then
        read -s -p "Enter your new password: " PASSWORD
        echo
    fi
else
    # If the service does not exist, inform the user about account creation
    show "Service $SERVICE_NAME does not exist. Before proceeding, please ensure you have created an account at: https://app.blockmesh.xyz/register?invite_code=2ad3bf83-bf2c-477a-8440-b98784cc71d7"
    read -p "Have you created an account? (yes/no): " account_created
    if [ "$account_created" != "yes" ]; then
        show "Please create an account before proceeding."
        exit 1
    fi
    # Get the user's email and password
    read -p "Enter your email: " EMAIL
    read -s -p "Enter your password: " PASSWORD
    echo
fi

# Create or update the systemd service file
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
cat <<EOL | sudo tee "$SERVICE_FILE" > /dev/null
[Unit]
Description=Blockmesh Service
After=network.target

[Service]
Type=simple
WorkingDirectory=$BLOCKMESH_DIR/target/x86_64-unknown-linux-gnu/release
ExecStart=$BLOCKMESH_DIR/target/x86_64-unknown-linux-gnu/release/blockmesh-cli login --email "${EMAIL}" --password "${PASSWORD}"
Restart=always
Environment="EMAIL=${EMAIL}"
Environment="PASSWORD=${PASSWORD}"

[Install]
WantedBy=multi-user.target
EOL
show "Service file created/updated at $SERVICE_FILE"

# Reload the systemd daemon to recognize the new service file
sudo systemctl daemon-reload

# Enable and start the service
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl start "$SERVICE_NAME"
show "Blockmesh service started."

# Display real-time logs
show "Displaying real-time logs. Press Ctrl+C to stop."
journalctl -u "$SERVICE_NAME" -f

# Exit the script after displaying logs
exit 0
