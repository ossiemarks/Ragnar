#!/bin/bash
# Fix permissions for OptarisDefense shell scripts

echo "Fixing permissions for OptarisDefense shell scripts..."

# Make all shell scripts executable
chmod +x *.sh

# Verify the permissions were set correctly
echo "Current permissions for shell scripts:"
ls -la *.sh

echo "All shell scripts now have execute permissions."
echo "You can now restart the OptarisDefense service with: sudo systemctl restart optaris_defense"