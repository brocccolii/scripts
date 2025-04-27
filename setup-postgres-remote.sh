#!/bin/bash

# Setup PostgreSQL for Remote Access
# Run this script on your PostgreSQL server

# Configuration variables
WEBSERVER_IP="10.5.1.10"
DB_USER="lumon_user"
DB_PASSWORD="your_secure_password"  # CHANGE THIS!
MAIN_DB="lumon_db"
DIAG_DB="lumon_diagnostic_db"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}PostgreSQL Remote Access Setup Script${NC}"
echo "Configuring access for web server at: ${WEBSERVER_IP}"
echo ""

# Check if script is run as root or with sudo
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root or with sudo${NC}" 
   exit 1
fi

# Detect PostgreSQL version
PG_VERSION=$(psql --version | grep -oP '\d+(?=\.\d+)')
if [ -z "$PG_VERSION" ]; then
    echo -e "${RED}PostgreSQL not found or unable to detect version${NC}"
    exit 1
fi

echo -e "${GREEN}Detected PostgreSQL version: ${PG_VERSION}${NC}"

# Configure PostgreSQL to listen on all interfaces
echo -e "${YELLOW}Configuring PostgreSQL to listen on all interfaces...${NC}"
PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
if [ -f "$PG_CONF" ]; then
    sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"
    sed -i "s/^listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"
else
    echo -e "${RED}PostgreSQL configuration file not found at ${PG_CONF}${NC}"
    exit 1
fi

# Configure pg_hba.conf for remote access
echo -e "${YELLOW}Configuring authentication for remote access...${NC}"
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
if [ -f "$PG_HBA" ]; then
    # Remove existing entries for our web server IP if they exist
    sed -i "/^host.*${WEBSERVER_IP}/d" "$PG_HBA"
    
    # Add new entries
    echo "# Lumon Industries Web Server Access" >> "$PG_HBA"
    echo "host    all             ${DB_USER}      ${WEBSERVER_IP}/32         md5" >> "$PG_HBA"
    echo "host    ${MAIN_DB}      ${DB_USER}      ${WEBSERVER_IP}/32         md5" >> "$PG_HBA"
    echo "host    ${DIAG_DB}      ${DB_USER}      ${WEBSERVER_IP}/32         md5" >> "$PG_HBA"
else
    echo -e "${RED}pg_hba.conf file not found at ${PG_HBA}${NC}"
    exit 1
fi

# Create database user and databases
echo -e "${YELLOW}Creating database user and databases...${NC}"
sudo -u postgres psql << EOF
-- Create user if not exists
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_user WHERE usename = '${DB_USER}') THEN
        CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
    END IF;
END
\$\$;

-- Create databases if not exist
SELECT 'CREATE DATABASE ${MAIN_DB} OWNER ${DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${MAIN_DB}')\gexec

SELECT 'CREATE DATABASE ${DIAG_DB} OWNER ${DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DIAG_DB}')\gexec

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE ${MAIN_DB} TO ${DB_USER};
GRANT ALL PRIVILEGES ON DATABASE ${DIAG_DB} TO ${DB_USER};

-- Connect to each database and grant schema privileges
\c ${MAIN_DB}
GRANT ALL ON SCHEMA public TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};

\c ${DIAG_DB}
GRANT ALL ON SCHEMA public TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
EOF

# Configure firewall (UFW)
echo -e "${YELLOW}Configuring firewall...${NC}"
if command -v ufw &> /dev/null; then
    ufw allow from ${WEBSERVER_IP} to any port 5432
    echo -e "${GREEN}UFW firewall configured${NC}"
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${WEBSERVER_IP}' port protocol='tcp' port='5432' accept"
    firewall-cmd --reload
    echo -e "${GREEN}firewalld configured${NC}"
else
    echo -e "${YELLOW}No firewall detected. Please configure manually if needed.${NC}"
fi

# Restart PostgreSQL
echo -e "${YELLOW}Restarting PostgreSQL...${NC}"
systemctl restart postgresql

# Verify PostgreSQL is listening on all interfaces
echo -e "${YELLOW}Verifying PostgreSQL configuration...${NC}"
netstat -nlp | grep 5432
if [ $? -eq 0 ]; then
    echo -e "${GREEN}PostgreSQL is listening on all interfaces${NC}"
else
    echo -e "${RED}PostgreSQL may not be properly configured for remote access${NC}"
fi

# Create a test connection script for the web server
echo -e "${YELLOW}Creating test connection script...${NC}"
cat > test_postgres_connection.py << 'EOFTEST'
#!/usr/bin/env python3
import psycopg2
import sys

# Connection parameters
DB_HOST = sys.argv[1] if len(sys.argv) > 1 else 'localhost'
DB_NAME = 'lumon_db'
DB_USER = 'lumon_user'
DB_PASSWORD = 'your_secure_password'  # Update this password

try:
    conn = psycopg2.connect(
        host=DB_HOST,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )
    
    cur = conn.cursor()
    cur.execute('SELECT version();')
    db_version = cur.fetchone()
    print(f"Successfully connected to PostgreSQL: {db_version[0]}")
    
    cur.close()
    conn.close()
    print("Connection test successful!")
    
except Exception as e:
    print(f"Error connecting to database: {str(e)}")
EOFTEST

chmod +x test_postgres_connection.py

echo -e "${GREEN}Setup completed!${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Update the database password in the script and .env file"
echo "2. Copy test_postgres_connection.py to your web server"
echo "3. Run 'python3 test_postgres_connection.py <postgres_server_ip>' from the web server"
echo "4. Configure your .env file on the web server with the correct database connection string"
echo ""
echo -e "${RED}IMPORTANT: Change the database password from 'your_secure_password' to something secure!${NC}"
