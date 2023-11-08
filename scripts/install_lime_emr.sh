#!/bin/sh

# Configurable variables for the application
REPOSITORY_URL="https://github.com/MSF-OCG/LIME-EMR-project-demo.git"
BRANCH_NAME="main"
APP_NAME="emr"
APP_URL="http://localhost/openmrs/login.htm"
CONTAINER_NAMES="openmrs-db openmrs-frontend openmrs-backend openmrs-gateway"

# List of dependencies to be installed
PACKAGES_TO_INSTALL="git curl vim screen gettext-base jq pwgen mlocate rsync software-properties-common apt-transport-https ca-certificates gnupg2"

# Configurable variables for installation and logs
INSTALL_DIR="/home/lime/$APP_NAME"
LOG_DIR="/var/logs/lime"
SUCCESS_LOG="$LOG_DIR/${APP_NAME}_install_script_success.log"
ERROR_LOG="$LOG_DIR/${APP_NAME}_install_script_error.log"
MAX_ATTEMPTS=5
MAX_RETRIES=100
COMPOSE_VERSION="2.23.0"

# Ensure the log directories and files exist
mkdir -p "$LOG_DIR"
: > "$SUCCESS_LOG" # Truncate/create the success log
: > "$ERROR_LOG" # Truncate/create the error log

# Function to log messages with timestamp
log_message() {
    local log_type=$1
    local message=$2
    local logfile=$3
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $log_type: $message" >> "$logfile"
}

# Function to remove log file if it is empty
remove_empty_log() {
    [ ! -s "$1" ] && rm -f "$1" && echo "Removed empty log file: $1"
}

# Function to check if a package is installed and at the latest version
is_package_installed_and_latest() {
    local package=$1
    if dpkg -s "$package" >/dev/null 2>&1; then
        local installed_version=$(dpkg -s "$package" | grep '^Version:' | awk '{print $2}')
        local available_version=$(apt list --upgradable 2>/dev/null | grep "^${package}/" | awk -F'[/ ]' '{print $3}')
        if [ "$installed_version" = "$available_version" ] || [ -z "$available_version" ]; then
            return 0 # Package is installed and up-to-date
        else
            return 1 # Package is installed but not up-to-date
        fi
    else
        return 2 # Package is not installed
    fi
}

# Install necessary packages non-interactively
install_packages() {
    local package
    local package_install_required=false
    if ! sudo apt-get update -y; then
        log_message "Error" "Failed to update package list." "$ERROR_LOG"
        return 1
    fi
    for package in $PACKAGES_TO_INSTALL; do
        is_package_installed_and_latest "$package"
        case $? in
            0) echo "$package is already installed and up to date." ;;
            1) 
                echo "$package is installed but not up to date. Upgrading..."
                package_install_required=true
                ;;
            2) 
                echo "$package is not installed. Installing..."
                package_install_required=true
                ;;
        esac
    done
    if [ "$package_install_required" = true ]; then
        if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $PACKAGES_TO_INSTALL --allow-unauthenticated; then
            log_message "Error" "Failed to install required packages." "$ERROR_LOG"
            return 1
        fi
        log_message "Success" "Required packages have been installed or updated." "$SUCCESS_LOG"
    else
        log_message "Success" "All required packages are already installed and up to date." "$SUCCESS_LOG"
    fi
}

# Function to install Docker Compose if not already installed
install_docker_compose() {
    if ! command -v docker-compose > /dev/null 2>&1; then
        echo "Docker Compose is not installed. Installing..."
        if sudo curl -L "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose \
            && sudo chmod +x /usr/local/bin/docker-compose; then
            log_message "Success" "Docker Compose version $COMPOSE_VERSION has been installed." "$SUCCESS_LOG"
        else
            log_message "Error" "Failed to install Docker Compose." "$ERROR_LOG"
            return 1
        fi
    else
        log_message "Success" "Docker Compose is already installed." "$SUCCESS_LOG"
    fi
}

# Function to determine the branch name based on the hostname
get_branch_name() {
    local last_char=$(hostname | awk '{print tolower(substr($0,length,1))}')
    case "$last_char" in
        d) BRANCH_NAME="dev";;
        t) BRANCH_NAME="qa";;
        p) BRANCH_NAME="main";;
        *)
          BRANCH_NAME="main"
          log_error "Hostname does not end with D, T, or P. Using default branch 'main'."
          return 1
          ;;
    esac
    log_success "Branch name set to '$BRANCH_NAME' based on the hostname."
    return 0
}

# Function to clone the repository
clone_repository() {
    if [ ! -d "$INSTALL_DIR/.git" ]; then
        echo "Cloning the repository branch '$BRANCH_NAME' into $INSTALL_DIR."
        if git clone --single-branch --branch "$BRANCH_NAME" "$REPOSITORY_URL" "$INSTALL_DIR" 2>>"$ERROR_LOG"; then
            log_message "Success" "Cloned the '$BRANCH_NAME' branch of the repository into $INSTALL_DIR." "$SUCCESS_LOG"
        else
            log_message "Error" "Failed to clone the '$BRANCH_NAME' branch of the repository into $INSTALL_DIR." "$ERROR_LOG"
            return 1
        fi
    else
        echo "Repository already cloned. Checking for updates..."
        if (cd "$INSTALL_DIR" && git fetch && git checkout "$BRANCH_NAME" && git pull origin "$BRANCH_NAME" 2>>"$ERROR_LOG"); then
            log_message "Success" "Updated the '$BRANCH_NAME' branch of the repository in $INSTALL_DIR." "$SUCCESS_LOG"
        else
            log_message "Error" "Failed to update the '$BRANCH_NAME' branch of the repository in $INSTALL_DIR." "$ERROR_LOG"
            return 1
        fi
    fi
}

# Function to start docker-compose
start_docker_compose() {
    echo "Starting docker-compose..."
    if (cd "$INSTALL_DIR" && docker-compose up -d) >> "$SUCCESS_LOG" 2>> "$ERROR_LOG"; then
        log_message "Success" "docker-compose started successfully." "$SUCCESS_LOG"
    else
        log_message "Error" "Failed to start docker-compose." "$ERROR_LOG"
        return 1
    fi
}

# Function to check if the containers are running
check_containers() {
    local all_running=true
    for container in $CONTAINER_NAMES; do
        if ! docker ps | grep "$container" > /dev/null 2>&1; then
            log_message "Error" "Container $container is not running." "$ERROR_LOG"
            all_running=false
        fi
    done

    if $all_running; then
        log_message "Success" "All containers are running." "$SUCCESS_LOG"
    else
        return 1
    fi
}

# Function to verify if the application URL is accessible
verify_application_url() {
    local attempt=1
    local max_attempts=$MAX_ATTEMPTS
    local url_status

    while [ $attempt -le $max_attempts ]; do
        url_status=$(curl -o /dev/null -s -w "%{http_code}\n" "$APP_URL")

        if [ "$url_status" = "200" ]; then
            log_message "Success" "The application URL $APP_URL is accessible." "$SUCCESS_LOG"
            return 0
        else
            log_message "Warning" "The application URL $APP_URL is not accessible. Attempt $attempt of $max_attempts." "$ERROR_LOG"
            sleep 5 # Wait before retrying
        fi
        attempt=$((attempt + 1))
    done

    log_message "Error" "The application URL $APP_URL is not accessible after $max_attempts attempts." "$ERROR_LOG"
    return 1
}

# Main installation function
install_application() {
    install_packages && install_docker_compose && clone_repository && \
    start_docker_compose && check_containers && verify_application_url

    # Check the exit status of the last command
    local status=$?
    if [ $status -eq 0 ]; then
        log_message "Success" "Installation and verifications completed successfully." "$SUCCESS_LOG"
    else
        log_message "Error" "Installation or verification failed." "$ERROR_LOG"
    fi
    remove_empty_log "$SUCCESS_LOG"
    remove_empty_log "$ERROR_LOG"
    return $status
}

# Start the installation process
install_application
