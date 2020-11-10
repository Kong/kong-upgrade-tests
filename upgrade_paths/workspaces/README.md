This is a test suite which tests workspace-related migrations in Kong.

When upgrading from non-workspace versions to workspace-enabled ones,
cassandra is not able to hold the connections on the new nodes until
the migration is complete. Because of this, we must add the
`--skip-migrating` flag when upgrading from Kong 2.0.0 in Cassandra:


```
# Postgres:
./test.sh -b 2.0.0 -t 2.1.0 upgrade_paths/workspaces
./test.sh -b 2.0.0 -t 2.1.1 upgrade_paths/workspaces
./test.sh -b 2.0.0 -t 2.1.2 upgrade_paths/workspaces
./test.sh -b 2.0.0 -t 2.1.3 upgrade_paths/workspaces
./test.sh -b 2.0.0 -t 2.1.4 upgrade_paths/workspaces
./test.sh -b 2.0.0 -t 2.2.0 upgrade_paths/workspaces
./test.sh -b 2.0.0 -t 2.2.1 upgrade_paths/workspaces

# Cassandra
./test.sh -b 2.0.0 -t 2.1.0 -d cassandra --skip-migrating upgrade_paths/workspaces
./test.sh -b 2.0.0 -t 2.1.1 -d cassandra --skip-migrating upgrade_paths/workspaces
./test.sh -b 2.0.0 -t 2.1.2 -d cassandra --skip-migrating upgrade_paths/workspaces
./test.sh -b 2.0.0 -t 2.1.3 -d cassandra --skip-migrating upgrade_paths/workspaces
./test.sh -b 2.0.0 -t 2.1.4 -d cassandra --skip-migrating upgrade_paths/workspaces
./test.sh -b 2.0.0 -t 2.2.0 -d cassandra --skip-migrating upgrade_paths/workspaces
./test.sh -b 2.0.0 -t 2.2.1 -d cassandra --skip-migrating upgrade_paths/workspaces
```
