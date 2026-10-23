FROM postgres:15

# pgTAP for tests/db.sql. Installing the package does nothing until a test
# runs CREATE EXTENSION, and the tests roll that back.
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-15-pgtap \
 && rm -rf /var/lib/apt/lists/*
