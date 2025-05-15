#!/bin/bash

# Default values
DROPLET_NAME="llm-logger"
SSH_KEY_NAME="do_llm_logger"

# Get droplet ID
DROPLET_ID=$(doctl compute droplet list --format ID,Name --no-header | grep ${DROPLET_NAME} | awk '{print $1}')

if [ -n "$DROPLET_ID" ]; then
    echo "Found droplet '${DROPLET_NAME}' with ID: ${DROPLET_ID}"
    echo "Deleting droplet..."
    doctl compute droplet delete -f ${DROPLET_ID}
    echo "Droplet deleted successfully!"
else
    echo "No droplet found with name '${DROPLET_NAME}'"
fi

# Get SSH key ID
SSH_KEY_ID=$(doctl compute ssh-key list --format ID,Name --no-header | grep ${DROPLET_NAME} | awk '{print $1}')

if [ -n "$SSH_KEY_ID" ]; then
    echo -e "\nFound SSH key '${DROPLET_NAME}' with ID: ${SSH_KEY_ID}"
    read -p "Would you like to delete the SSH key from Digital Ocean? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if doctl compute ssh-key delete -f ${SSH_KEY_ID} > /dev/null 2>&1; then
            echo "SSH key deleted from Digital Ocean"
            echo -e "\nNote: The local SSH key at ~/.ssh/${SSH_KEY_NAME} still exists."
            echo "To delete it manually, run:"
            echo "rm ~/.ssh/${SSH_KEY_NAME} ~/.ssh/${SSH_KEY_NAME}.pub"
        else
            echo "Error: Failed to delete SSH key"
        fi
    fi
else
    echo "No SSH key found with name '${DROPLET_NAME}'"
fi
