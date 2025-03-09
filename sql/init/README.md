# SQL Initialization Scripts

This directory contains scripts that are executed during the PostgreSQL container initialization.

## Files

- `init-db.sh`: Sets database configuration parameters, creates necessary roles and schemas, and grants appropriate permissions.
- `update-pg-hba.sh`: Updates the PostgreSQL Host-Based Authentication configuration to allow connections from Docker containers.

## Execution Order

The scripts are executed in the following order (as defined in the docker-compose.yml file):

1. Main migration script (from `/migrations/000_main_migration.sql`)
2. `init-db.sh`
3. `update-pg-hba.sh`

## Environment Variables

These scripts use the following environment variables:

- `POSTGRES_USER`: The PostgreSQL username (default: postgres)
- `POSTGRES_PASSWORD`: The PostgreSQL password
- `POSTGRES_DB`: The database name (default: url_shortener)
- `JWT_SECRET`: Secret key for JWT tokens
- `MASTER_PASSWORD`: Master password for admin operations

## Adding New Initialization Scripts

If you need to add new initialization scripts:

1. Add them to this directory
2. Make them executable (`chmod +x your_script.sh`)
3. Add them to the `volumes` section in the `db` service in `docker-compose.yml`, following the numbering pattern:

```yaml
volumes:
  - ./migrations/000_main_migration.sql:/docker-entrypoint-initdb.d/1-schema.sql
  - ./sql/init/init-db.sh:/docker-entrypoint-initdb.d/2-init-db.sh
  - ./sql/init/update-pg-hba.sh:/docker-entrypoint-initdb.d/3-update-pg-hba.sh
  - ./sql/init/your_script.sh:/docker-entrypoint-initdb.d/4-your-script.sh
``` 