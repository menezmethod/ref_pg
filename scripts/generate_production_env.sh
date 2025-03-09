#!/bin/bash
# Script to generate secure random values for production environment

# Function to generate a secure random string
generate_secure_string() {
  openssl rand -base64 32 | tr -d '/+=' | cut -c1-32
}

# Create .env.production file from template
cp .env.production .env.production.tmp

# Generate secure random passwords
POSTGRES_PASSWORD=$(generate_secure_string)
JWT_SECRET=$(generate_secure_string)
PGADMIN_PASSWORD=$(generate_secure_string)
REDIS_PASSWORD=$(generate_secure_string)

# Update the .env.production file with the generated passwords
sed -i '' "s/\${POSTGRES_PASSWORD}/$POSTGRES_PASSWORD/g" .env.production.tmp
sed -i '' "s/\${JWT_SECRET}/$JWT_SECRET/g" .env.production.tmp
sed -i '' "s/\${PGADMIN_EMAIL}/admin@yourdomain.com/g" .env.production.tmp
sed -i '' "s/\${PGADMIN_PASSWORD}/$PGADMIN_PASSWORD/g" .env.production.tmp
sed -i '' "s/\${REDIS_PASSWORD}/$REDIS_PASSWORD/g" .env.production.tmp

mv .env.production.tmp .env.production

echo "Production environment file created with secure random passwords."
echo ""
echo "IMPORTANT: Make sure to save these credentials in a secure password manager!"
echo "PostgreSQL Password: $POSTGRES_PASSWORD"
echo "JWT Secret: $JWT_SECRET"
echo "PgAdmin Password: $PGADMIN_PASSWORD"
echo "Redis Password: $REDIS_PASSWORD"
echo ""
echo "These values have been saved to .env.production" 