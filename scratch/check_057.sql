-- Check if migration 057 is in schema_migrations
SELECT version, filename FROM schema_migrations WHERE version = 57;
