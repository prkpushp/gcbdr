#!/bin/bash
#Define Variables
SOURCE_VM_NAME=$1
SOURCE_VM_PROJECT=qwiklabs-gcp-04-34e2d4c38323
BRS_PROJECT=qwiklabs-gcp-04-34e2d4c38323
TARGET_VM_PROJECT="$SOURCE_VM_PROJECT"
VAULT_NAME=backup-vault
SOURCE_VM_NETWORK_PROJECT="$SOURCE_VM_PROJECT"
SOURCE_VM_VPC=custom-network
EPOCH_TIME=`date +%s`
RESTORE_SUFFIX="-restore-"
RESTORED_VM_NAME="${SOURCE_VM_NAME}${RESTORE_SUFFIX}${EPOCH_TIME}"
SOURCE_VM_SUBNET=subnet-b
TARGET_ZONE=us-east1-b
TARGET_ZONE2=us-east1-c
TIMEOUT=600  # Timeout in seconds (10 minutes)
INTERVAL=10  # Interval between checks (10 seconds)


# Check if SOURCE_VM_NAME is provided as an argument
if [[ -z "$1" ]]; then
  echo "Error: SOURCE_VM_NAME is not set. Usage: ./script.sh <SOURCE_VM_NAME>"
  exit 1
fi






# Fetch the data source name for the VM
VM_VAULT_DATASOURCE=$(gcloud backup-dr data-sources list \
  --project=$BRS_PROJECT \
  --backup-vault=$VAULT_NAME \
  --location=us-east1 \
  --filter="dataSourceGcpResource.computeInstanceDatasourceProperties.name~'${SOURCE_VM_NAME}$'" \
  --format="value(name)")

# Check if the gcloud command succeeded
if [[ $? -ne 0 || -z "$VM_VAULT_DATASOURCE" ]]; then
  echo "Error: Failed to retrieve the data source for the VM '$SOURCE_VM_NAME'."
  exit 1
else
  echo -e "\nVM Datasource=$VM_VAULT_DATASOURCE"
fi

# Fetch the list of backups for the data source
backups=$(gcloud backup-dr backups list --data-source="$VM_VAULT_DATASOURCE" --format="json")

# Check if backups were fetched successfully
if [[ -z "$backups" || "$backups" == "[]" ]]; then
  echo "No backups found for data source: $VM_VAULT_DATASOURCE"
  exit 1
fi

# Parse and display available backup creation dates
echo "Available Backups:"
creation_dates=($(echo "$backups" | jq -r '.[].createTime'))

if [[ ${#creation_dates[@]} -eq 0 ]]; then
  echo "No backup creation dates found."
  exit 1
fi

# Sort the creation dates and get the latest one
sorted_dates=($(printf "%s\n" "${creation_dates[@]}" | sort -r))
latest_date="${sorted_dates[0]}"

# Display the list with the default (latest) backup highlighted, formatted
for i in "${!sorted_dates[@]}"; do
  formatted_date=$(date -u -d "${sorted_dates[$i]}" +"%Y-%m-%d %H:%M")
  if [[ "${sorted_dates[$i]}" == "$latest_date" ]]; then
    echo "$((i + 1)). $formatted_date (default)"
  else
    echo "$((i + 1)). $formatted_date"
  fi
done

# Prompt the user to select a backup
read -p "Enter the number of the backup you want to select [default: 1]: " selection

# Set the default selection to the latest backup if no input is provided
if [[ -z "$selection" ]]; then
  selection=1
fi

# Validate user input
if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt "${#sorted_dates[@]}" ]]; then
  echo "Invalid selection. Please enter a valid number."
  exit 1
fi

# Get the selected backup details
selected_date="${sorted_dates[$((selection - 1))]}"
selected_backup=$(echo "$backups" | jq -r ".[] | select(.createTime==\"$selected_date\")")

# Display the selected backup details
echo "You selected backup created on: $selected_date"
#echo "Backup details:"
#echo "$selected_backup" | jq

BKP2RSTR=$(echo "$selected_backup" | jq -r '.name')

# Check if BKP2RSTR was successfully extracted
if [[ -z "$BKP2RSTR" ]]; then
  echo "Error: Could not extract the backup name."
  exit 1
fi

# Display the backup name
echo -e "\nBackup datasource to restore: $BKP2RSTR"


# Define the command
restore_command=$(cat <<EOF
gcloud backup-dr backups restore compute $BKP2RSTR \
    --name=$RESTORED_VM_NAME \
    --metadata=startup-script='echo hello>/tmp/hello.txt' \
    --target-zone=$TARGET_ZONE \
    --target-project=$TARGET_VM_PROJECT \
    --create-disk=device-name=persistent-disk-1,replica-zones='https://www.googleapis.com/compute/v1/projects/$SOURCE_VM_PROJECT/zones/$TARGET_ZONE https://www.googleapis.com/compute/v1/projects/$SOURCE_VM_PROJECT/zones/$TARGET_ZONE2' \
    --network-interface=network=projects/$SOURCE_VM_NETWORK_PROJECT/global/networks/$SOURCE_VM_VPC,subnet=projects/$SOURCE_VM_NETWORK_PROJECT/regions/us-east1/subnetworks/$SOURCE_VM_SUBNET \
    --log-http \
    --format=json
EOF
)

# Execute the command
echo -e "\nExecuting restore command..."
if eval "$restore_command" > /dev/null 2>&1; then
    echo -e "\nRestore command executed successfully. However it may take few minutes to get the VM ready to use!"
    echo -e "\nYou can also check the logs at the following URL: https://console.cloud.google.com/backupdr/jobs/list?project=$BRS_PROJECT"
    echo "Checking VM status every $INTERVAL seconds for $TIMEOUT seconds..."
    # Start time to track the duration
    START_TIME=$(date +%s)

    # Loop to check VM status
    while true; do
        # Check if the VM exists
        VM_EXISTS=$(gcloud compute instances describe $RESTORED_VM_NAME \
            --project=$SOURCE_VM_PROJECT \
            --zone=$TARGET_ZONE \
            --format='get(name)' 2>/dev/null)

        if [ -z "$VM_EXISTS" ]; then
            echo "Looks like the VM $RESTORED_VM_NAME is still being created..."
        else
            # Get the current VM status
            VM_STATUS=$(gcloud compute instances describe $RESTORED_VM_NAME \
                --project=$SOURCE_VM_PROJECT \
                --zone=$TARGET_ZONE \
                --format='get(status)')

            # Check if VM status is running
            if [[ "$VM_STATUS" == "RUNNING" ]]; then
                echo "VM $RESTORED_VM_NAME is now RUNNING."
                break
            fi
        fi

        # Check if we've reached the timeout
        CURRENT_TIME=$(date +%s)
        ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
        if (( ELAPSED_TIME >= TIMEOUT )); then
            echo "Timeout reached. VM $RESTORED_VM_NAME is still not RUNNING."
            break
        fi

        # Wait for the specified interval before the next check (10 seconds)
        sleep $INTERVAL
    done

    echo -e "\nSource VM: '$SOURCE_VM_NAME' \n Restored VM:  '$RESTORED_VM_NAME'."
else
    # Capture the exit code
    exit_code=$?
    echo -e "\nError: Restore command failed."
    echo -e "\nPlease check the restore_error.log file for more details."
    echo -e "\nYou can also check the logs at the following URL: https://console.cloud.google.com/backupdr/jobs/list?project=$BRS_PROJECT"

    # Append the timestamped error to the log file
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restore command failed with exit code $exit_code."
        eval "$restore_command" 2>&1
    } >> restore_error.log
    
    exit $exit_code
fi
