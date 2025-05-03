#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration ---
IMAGE_NAME="radcxp-linux-builder-alpine-arm"
CONTAINER_NAME="radcxp-builder-instance"
# Define host path using PWD for script location independence
HOST_OUTPUT_DIR="$(pwd)/build/linux/arm64/release"
# Define the expected output directory within the container
CONTAINER_BUILD_DIR="/app/build/linux/arm64/release/bundle"
DOCKERFILE="Dockerfile.linux-arm"

# --- Main Script ---

echo "--- Building Docker image (${IMAGE_NAME}) ---"
# Explicitly specify platform for clarity, especially on macOS hosts
docker build --platform linux/arm64 -t ${IMAGE_NAME} -f ${DOCKERFILE} .
echo "--- Docker image build complete ---"

echo "--- Creating build container (${CONTAINER_NAME}) ---"
# Create the container from the image, but don't run the build command yet
# This allows us to use 'docker cp' later
docker create --platform linux/arm64 --name ${CONTAINER_NAME} ${IMAGE_NAME}
echo "--- Build container created ---"

echo "--- Starting build process inside container ---"
# Start the container and execute the build command (CMD from Dockerfile)
docker start -a ${CONTAINER_NAME}
echo "--- Build process finished ---"

echo "--- Copying build artifacts from container ---"
# Ensure the host output directory exists
mkdir -p "${HOST_OUTPUT_DIR}"

# Copy the 'bundle' directory from the container to the host output directory
# Note: We copy the parent directory content to get the 'bundle' folder itself
docker cp "${CONTAINER_NAME}:${CONTAINER_BUILD_DIR}/.." "${HOST_OUTPUT_DIR}"
echo "--- Artifacts copied to ${HOST_OUTPUT_DIR}/bundle ---"

echo "--- Cleaning up build container ---"
docker rm ${CONTAINER_NAME}
echo "--- Cleanup complete ---"

echo "--- Linux ARM build process finished successfully ---"
echo
