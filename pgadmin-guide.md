# PgAdmin Guide for URL Shortener

This guide provides instructions on how to access and use pgAdmin to manage the PostgreSQL database for the URL Shortener service.

## Accessing pgAdmin

1. Open your browser and navigate to [https://pgadmin.menezmethod.com](https://pgadmin.menezmethod.com) or, if running locally, [http://localhost:5050](http://localhost:5050)

2. Login with the following credentials:
   - **Email**: `luisgimenezdev@gmail.com` (or the value of PGADMIN_EMAIL environment variable)
   - **Password**: The value of PGADMIN_PASSWORD environment variable

## Connecting to the URL Shortener Database

1. After logging in, right-click on "Servers" in the left sidebar and select "Create" > "Server..."

2. In the "General" tab, enter a name for the connection (e.g., "URL Shortener DB")

3. Switch to the "Connection" tab and enter the following details:
   - **Host name/address**: `db` (when using within Coolify network) or `localhost` (when connecting from outside)
   - **Port**: `5432` (inside Coolify) or `5433` (from outside Coolify)
   - **Maintenance database**: `url_shortener` (or the value of POSTGRES_DB)
   - **Username**: `postgres` (or the value of POSTGRES_USER)
   - **Password**: `postgres` (or the value of POSTGRES_PASSWORD)

4. Click "Save" to connect to the database

## Database Structure

The URL Shortener database contains the following main tables:

- **short_links**: Contains all created short links
- **urls**: Stores original URLs
- **users**: User accounts
- **api_keys**: API keys for authentication
- **link_clicks**: Tracks clicks on short links
- **analytics_events**: General analytics events

## Common Tasks

### Viewing Short Links

1. Navigate to Servers > URL Shortener DB > Databases > url_shortener > Schemas > public > Tables > short_links
2. Right-click on the "short_links" table and select "View/Edit Data" > "All Rows"

### Running SQL Queries

1. Click on the "Query Tool" button in the top toolbar
2. Enter your SQL query in the editor
3. Click the "Execute/Refresh" button to run the query

### Example Queries

```sql
-- Get all short links with their original URLs
SELECT s.code, u.original_url, s.created_at, s.expires_at 
FROM short_links s
JOIN urls u ON s.url_id = u.id;

-- Get click statistics for each short link
SELECT s.code, COUNT(lc.id) as click_count
FROM short_links s
LEFT JOIN link_clicks lc ON s.id = lc.short_link_id
GROUP BY s.code
ORDER BY click_count DESC;

-- Find expired links
SELECT s.code, u.original_url, s.expires_at
FROM short_links s 
JOIN urls u ON s.url_id = u.id
WHERE s.expires_at < NOW();
```

## Backing Up the Database

1. Right-click on the "url_shortener" database
2. Select "Backup..."
3. Configure your backup settings
4. Click "Backup" to create a backup file

## Troubleshooting Connection Issues

If you cannot connect to the database:

1. Verify that the database container is running
2. Check that the port forwarding is correctly set up (5433:5432)
3. Ensure your network allows connections to the specified port
4. Verify that the credentials are correct

## Security Notes

- The pgAdmin interface should be secured with HTTPS in production
- Consider implementing IP restrictions for accessing pgAdmin in production
- Regularly update the pgAdmin password
- Do not share database credentials in public repositories 