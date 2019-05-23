# kong-upgrade-tests

A framework to test Kong upgrade paths between major versions.

Goals:
- test migrations between versions X and Y
- test Admin API behavior and content once migrated to version Y
- test Proxy behavior once migrated to version Y

## Writing tests

1. Create a folder under `upgrade_paths` with a structure looking like the
following example:

```
upgrade_paths
└── 0.14_0.15
    ├── before
    │   ├── 001-api.json
    │   └── 002-rate-limiting.json
    ├── migrating
    │   ├── 001-api.json
    │   └── 002-rate-limiting.json
    └── after
        ├── 001-api.json
        ├── 002-routes-services.json
        ├── 003-rate-limiting.postgres.json
        └── 003-rate-limiting.cassandra.json
```

Name it however you want, here we chose `0.12_0.13`. Inspire yourself from the
existing upgrade paths tests to write your own.

You can name your tests however you want as long as they have a `.json` extension
and are placed under `before/`, `migrating/` or `after/`. The tests will run in
lexicographical order, so we recommend the convention of numbering them as
shown above.

Tests are written in a [JSON-based DSL](#json-dsl-for-tests), documented below.
If the filename contains a database name (`postgres` or `cassandra`), it will
only run for that file.

2. Run the `test.sh` script (see [Usage](#usage))

This script will do the following:

1. Install a base version
2. Migrate a test database to the base version, bootstrapping if needed
3. Start Kong
4. **Run all tests in the `before/` directory**
5. Install the target version
6. **Run `kong migrations up`** from the target version folder
7. **Run all tests in the `migrating/` directory** using two nodes, one in the base
   version and one in the target version.
8. **Run `kong migrations finish`**
9. Stop kong base version node
10. **Run all tests in the `after/` directory** on the target kong node
11. Stop the target kong node
12. Cleanup

## Usage

```
Usage: ./test.sh [options...] --base <base> --target <target> TEST_SUITE

Arguments:
  -b,--base          base version
  -t,--target        target version
  TEST_SUITE         path to test suite

Options:
  -d,--database      database (default: postgres)
  -r,--repo          repository (default: kong)
  -f,--force         cleanup cache and force git clone
```

Examples:
```
 ./test.sh -b 0.10.0 -t 0.11.1 upgrade_paths/0.10_to_0.11
 ./test.sh -b 0.10.0 -t 0.11.1 upgrade_paths/0.10_to_0.11_edge_case_foo

 ./test.sh -d cassandra -b 0.10.0 -t 0.11.1 upgrade_paths/0.10_to_0.11

 ./test.sh -b 0.11.0 -t 0.12.0 upgrade_paths/0.11_0.12
 ./test.sh -b 0.11.0 -t 0.12.1 upgrade_paths/0.11_0.12

 ./test.sh -b kong-private:0.10.0 -t kong-private:0.11.0 upgrade_paths/0.10_to_0.12
 ./test.sh -b kong-ee:0.10.0 -t kong-ee:0.11.0 upgrade_paths/0.10_to_0.12
 ./test.sh -b kong:0.12.1 -t kong-private:0.13.0preview1 upgrade_paths/0.12_0.13

 ./test.sh -b kong:0.14.1 -t kong:next upgrade_paths/0.14.1_0.15.0
```

## JSON DSL for tests

Tests are written in a JSON-based DSL, described below:

### Synopsis

```json
[

  [ "my_consumer",
    [ "admin", "POST", "/consumers", { "username": "bob"} ],
    [ 201, { "username": "bob" } ]
  ],

  [ "run an arbitrary shell command, matches regex aginst stdout",
    [ "shell", "echo 'hellooooo world'" ],
    [ 0, {
      "%stdout": "hello+ world"
    } ]
  ],

  [ "add credentials to consumer, uses 'my_consumer' defined above",
    [ "admin", "POST", "/consumers/#{my_consumer.id}/key-auth", { "key": "secret" } ],
    [ 201, {
      "key": "secret",
      "consumer_id": "#{my_consumer.id}"
    } ]
  ],

  [ "run a postgresql SQL statement, get the results back",
    [ "psql", "SELECT * FROM services" ],
    [ 1, [
      { "name": "service_1",
        "id": "c75e22b7-1e77-41b1-9d8b-e1704d4d08ae",
        ...
      },
      { "name": "service_2",
        "id": "3ac42fe7-898e-4ed3-ac13-3dde3fa329d0",
        ...
      }
    ]
    } ]
  ],

  [ "run a Cassandra CQL statement, get the results back",
    [ "cql", "SELECT * FROM services" ],
    [ 2, {
      "type": "ROWS",
      "1": {
        "name": "service_1",
        "id": "c75e22b7-1e77-41b1-9d8b-e1704d4d08ae",
        ...
      },
      "2": {
        "name": "service_2",
        "id": "3ac42fe7-898e-4ed3-ac13-3dde3fa329d0",
        ...
      }
    ]
    } ]
  ],


]
```

### Entries

A test file contains an array of entries. Each entry has the following format:

```
[ <name>, <request>, <response> ]
```

The `<name>` can be used in subsequent entries to match portions of the entry's response.
If the entry's response is not needed beyond this test, the `name` field can be
used as a comment field for describing the test.

The `<request>` field has the following format:

```
[ <type>, ... ]
```

Where `<type>` is either `"shell"` for a shell command, or one of the available HTTP
clients for an HTTP request:

* `"admin"`
* `"proxy"`
* `"admin_ssl"`
* `"proxy_ssl"`
* `"admin_2"`
* `"proxy_2"`
* `"admin_ssl_2"`
* `"proxy_ssl_2"`

The types that end in `_2` will do requests against the target version, while the others will
use the kong in the base version.

Example:

```
[ "my_consumer",
  [ "admin", "POST", "/consumers", { "username": "bob"} ],
  [ 201, { "username": "bob" } ]
]
```

### HTTP requests

HTTP requests have the following format:

```
[ <client>, <method>, <path>, <body?>, <headers?> ]
```

* `<client>` is one of the four HTTP clients listed above;
* `<method>` is an HTTP method, e.g. `"GET"`;
* `<path>` is the path request, e.g. `"/consumers"`;
* `<body>` (optional) is a JSON object with the API request, e.g. `{ "username": "bob" }`;
* `<headers>` (optional) is a JSON object with additional HTTP headers for the
  request, e.g. `{ "Host": "example.com" }`;

The `path`, `body` and `headers` values support string interpolation, and
`body` and `headers` support regular expression matching (see below).

Example:

```
[ "admin", "POST", "/services", { "url": "http://example.com/something" } ]
```

### HTTP responses

```
[ <status>, <body?>, <headers?> ]
```

* `<status>` is a number with the HTTP status
* `<body>` (optional) is a JSON object that should match the API response, e.g. `{ "username": "bob" }`;
* `<headers>` (optional) is a JSON object with HTTP headers that are expected to
  be present in the response, e.g. `{ "WWW-Authenticate": "Key realm=\"kong\"" }`;

Note that the `body` object is a subset of the expected response. For example,
`{ "total": 2 }` will match successfully if the response is `{ "total": 2,
"data": [ "foo", "bar" ] }`. Likewise, `headers` does not need to be the complete
set of received headers.

The `<path>`, `<body>` and `<headers>` values support string interpolation, and
`<body>` and `<headers>` support regular expression matching (see below).

Example:

```
[ 429, {
  "message": "API rate limit exceeded"
}, {
  "X-RateLimit-Limit-hour": "1",
  "X-RateLimit-Remaining-hour": "0"
} ]
```

### Shell requests

```
[ "shell", <execute> ]
```

* `<execute>` is a string with a command to run, e.g. `"resty scripts/my_script.lua"`

No string interpolation or regular expression matching is performed in the `<execute>` string.

Example:

```
[ "shell", "resty scripts/wait_for_hour.lua" ]
```

### Shell responses

```
[ <status>, <body?> ]
```

* `<status>` is a number with the shell exit code status
* `<body>` (optional) is a JSON object, with optional keys `"stdout"` and `"stderr"`,
  whose string values should match the output produced by the command in standard output
  and standard error.

String interpolation and regular expression matching are both performed in the `<body>`
strings. In particular, one can use the `"%stdout"` key to match a regular expression
against the output.

Example:

```
[ 0 ]
```

### PSQL requests

```
[ "psql", <sql> ]
```

* `<sql>` is a string with one or more sql statements separated by `;`.

Example:

```
[ "psql", "SELECT * FROM routes" ]
```

### PSQL responses

```
[ <number-of-statements>, <body> ]
```

* `<number-of-statements>` is the number of SQL statements that were contained on the `sql`
   portion of the request. For example, the string `"SELECT * FROM routes; SELECT * FROM services"`
   contains 2 SQL statements.
* `<body>` is an array with zero or more results. If there are results, they will be encoded as
  json objects. Their format depends on the SQL statements introduced.


### CQL

```
[ "cql", <cql> ]
```

* `<cql>` is a string with one cql statement.

Example:

```
[ "cql", "SELECT * FROM routes" ]
```

### CQL responses

```
[ <number-of-rows>, <body> ]
```

* `<number-of-rows>` is the number of rows returned by the body. Literally `#body`.
* `<body>` is a table returned by `lua-cassandra`. It usually has a `type` value. Expressions
  returning rows (such as a Select will have a `ROWS` type). `body[1]`
  would be the first row, `body[2]` the second one, and so on. Other types of requests
  could have other formats. See the lua-cassandra docs for examples.

### String interpolation and regular expressions

**String interpolation** in the format `#{name.field}` can be used in `path`, `body` values
and `headers` values.

If any of the keys in `body` or `headers` starts with `%`, the corresponding value
is taken to be a **PCRE regular expression**. For example, `{ "%id": "^[0-9a-fA-F]+$" }`
in the entry's response body object means that the `id` field is expected to be
a non-empty string in hexadecimal format.

## TODO

- Configure Cassandra/PostgreSQL via ENV variables
- Redirect to both stdout and log file
- TAP
