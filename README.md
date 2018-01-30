# kong-upgrade-tests

A framework to test Kong upgrade paths between major versions.

Goals:
- test migrations between versions X and Y
- test Admin API behavior and content once migrated to version Y
- test Proxy behavior once migrated to version Y

## Writing tests

1. Create a folder under `upgrade_paths` with the following structure:
```
upgrade_paths
└── 0.12_0.13
    ├── admin_test.lua   # optional
    ├── proxy_test.lua   # optional
    └── data.json
```

Name it however you want, here we chose `0.12_0.13`. As this document is WIP,
inspire yourself from the existing upgrade paths tests to write your own.

2. Run the `test.sh` script (see [Usage](#usage))

This script will do the following:

    1. Install a base version
    2. Migrate a test database to the base version
    3. Start Kong
    4. Populate it via the `data.json` file (declaratively)
    5. Stop Kong
    6. Install the target version
    7. **Run the migrations** -> on non success, we caught an error
    8. Start Kong
    8. **Run a script against the Admin API** -> verify the migration left the data in the desired state
    9. **Run a script against the proxy** -> verify the behavior of the proxy once migrated
    10. Stop Kong
    11. Cleanup

## Usage

```
Usage: ./test.sh [options...] --base <base> --target <target> TEST_SUITE

Arguments:
  -b,--base          base version
  -t,--target        target version
  TEST_SUITE         path to test suite

Options:
  -d,--database      database
  -r,--repo          repository
  -f,--force         cleanup cache and force git clone
```

Example:
```
 ./test.sh -b 0.10.0 -t 0.11.1 upgrade_paths/0.10_0.11
```

