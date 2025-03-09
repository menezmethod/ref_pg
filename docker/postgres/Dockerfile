FROM postgres:15

# Copy initialization scripts
COPY migrations/000_main_migration.sql /docker-entrypoint-initdb.d/1-schema.sql
COPY sql/init/init-db.sh /docker-entrypoint-initdb.d/2-init-db.sh
COPY sql/init/update-pg-hba.sh /docker-entrypoint-initdb.d/3-update-pg-hba.sh

# Set permissions
RUN chmod +x /docker-entrypoint-initdb.d/2-init-db.sh
RUN chmod +x /docker-entrypoint-initdb.d/3-update-pg-hba.sh 