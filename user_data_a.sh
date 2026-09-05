#!/bin/bash
# Bootstrap script for Version A instances.
# Sets up a lightweight web server on port 80 that returns "Version A".

set -euo pipefail

mkdir -p /var/www/html

cat > /var/www/html/index.html <<'EOF'
Version A
EOF

# Serve on port 80 using Python's built-in HTTP server. Runs in the background
# so the rest of the EC2 boot process can continue normally.
cd /var/www/html
nohup python3 -m http.server 80 > /var/log/http-server.log 2>&1 &
