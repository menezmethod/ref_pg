# URL Shortener Database Migrations

This directory contains the database migrations for the URL Shortener service.

## Migration Structure

- `000_main_migration.sql`: The consolidated migration file that contains the complete database schema.
- `archive/`: Directory containing the original incremental migration files (for reference only).

## Migration Strategy

For this project, we've consolidated all migrations into a single main file (`000_main_migration.sql`) that creates the entire schema at once. This approach offers several benefits:

1. Simplified initial setup
2. Easier to understand the complete database structure
3. More predictable behavior during initialization
4. Reduced potential for migration conflicts

## Adding New Schema Changes

If you need to make changes to the schema in the future, you have two options:

1. **Recommended for development**: Update the consolidated migration file directly
2. **For production changes**: Create incremental migration files (e.g., `001_add_new_feature.sql`) that will run after the main migration

## Migration Order

Migrations are executed in alphabetical order by PostgreSQL's initialization scripts. The `000_` prefix ensures our consolidated migration runs first.

## Testing Migrations

To test migrations:

```bash
# Start all services
./scripts/start_and_test.sh

# Verify database structure
./scripts/verify_db_structure.sh
``` 