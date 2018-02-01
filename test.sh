#!/usr/bin/env bash

# kong test instance configuration
DATABASE=postgres
ADMIN_LISTEN=127.0.0.1:18001
PROXY_LISTEN=127.0.0.1:18000
ADMIN_LISTEN_SSL=127.0.0.1:18444
PROXY_LISTEN_SSL=127.0.0.1:18443

POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=5432
POSTGRES_DATABASE=kong_upgrade_path_tests

CASSANDRA_CONTACT_POINT=127.0.0.1
CASSANDRA_PORT=9042
CASSANDRA_KEYSPACE=kong_upgrade_path_tests

# constants
root=`pwd`
cache_dir=$root/cache
tmp_dir=$root/tmp
log_file=$root/run.log
test_sep="==>"

# arguments
base_version=
target_version=
base_repo=kong
target_repo=kong
test_suite_dir=
ssh_key=$HOME/.ssh/id_rsa

# control variables
base_repo_dir=
target_repo_dir=
ret1=
ret2=

export KONG_PREFIX=$root/tmp/kong
export KONG_ADMIN_LISTEN=$ADMIN_LISTEN
export KONG_PROXY_LISTEN=$PROXY_LISTEN
export KONG_ADMIN_LISTEN_SSL=$ADMIN_LISTEN_SSL
export KONG_PROXY_LISTEN_SSL=$PROXY_LISTEN_SSL

# clear log file for this run
echo "" > $log_file

# save original stdout and stderr fds
exec 5<&1
exec 6<&2
## our log file is stdout and stderr
exec 1>$log_file 2>&1

main() {
    if ! [ -x "$(command -v luarocks)" ]; then
        show_error "'luarocks' is not available in \$PATH"
    fi

    if ! [ -x "$(command -v resty)" ]; then
        show_error "'resty' is not available in \$PATH"
    fi

    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            -h|--help)
                show_help
                exit 0
                ;;
            -d|--database)
                DATABASE=$2
                shift
                ;;
            -b|--base)
                base_version=$2
                shift
                ;;
            -t|--target)
                target_version=$2
                shift
                ;;
            -f|--force)
                rm -rf $cache_dir
                ;;
            --ssh-key)
                ssh_key=$2
                shift
                ;;
            *)
                test_suite_dir=$key
                break
                ;;
        esac

        shift
    done

    if [[ ! -d "$test_suite_dir" ]]; then
        wrong_usage "TEST_SUITE is not a directory: $test_suite_dir"
    fi

    test_suite_dir=$(realpath $test_suite_dir)

    if [[ ! -f "$test_suite_dir/data.json" ]]; then
        wrong_usage "TEST_SUITE does not contain valid data.json"
    fi

    if [ -z "$base_version" ]; then
        wrong_usage "missing argument: --base"
    fi

    if [ -z "$target_version" ]; then
        wrong_usage "missing argument: --target"
    fi

    if [[ "$base_version" == "$target_version" ]]; then
        wrong_usage "base and target version should be different"
    fi

    case $DATABASE in
        postgres|cassandra)
            ;;
        *)
            wrong_usage "unknown database: $DATABASE - check with your local Kong developer to add support for it"
            ;;
    esac

    parse_version_arg $base_version
    base_version=$ret1
    if [ -n "$ret2" ]; then
        base_repo=$ret2
    fi

    parse_version_arg $target_version
    target_version=$ret1
    if [ -n "$ret2" ]; then
        target_repo=$ret2
    fi

    rm -rf $tmp_dir
    mkdir -p $cache_dir $tmp_dir

    #kong prepare
    #kong health

    # Example:
    # ./test.sh -b 0.11.2 -t 0.12.1
    #
    #   creates the following structure:
    #
    #   ├── cache               -> long-lived cache of git repositories
    #   │   └── kong
    #   ├── err.log             -> error logs for this run
    #   ├── test.sh
    #   └── tmp
    #       ├── kong-0.11.2     -> short-lived checkout of 0.11.2
    #       └── kong-0.12.1     -> short-lived checkout of 0.12.1

    clone_or_pull_repo $base_repo
    if [[ "$base_repo" != "$target_repo" ]]; then
        clone_or_pull_repo $target_repo
    fi

    prepare_repo $base_repo $base_version
    base_repo_dir=$ret1

    prepare_repo $target_repo $target_version
    target_repo_dir=$ret1

    # setup database

    if [[ "$DATABASE" == "postgres" ]]; then
        echo "Dropping PostgreSQL database '$POSTGRES_DATABASE'"
        dropdb -U postgres -h $POSTGRES_HOST -p $POSTGRES_PORT $POSTGRES_DATABASE \
             || show_warning "dropdb failed with: $?"
        createdb -U postgres -h $POSTGRES_HOST -p $POSTGRES_PORT $POSTGRES_DATABASE \
            || show_error "createdb failed with: $?"

        export KONG_DATABASE=$DATABASE
        export KONG_PG_HOST=$POSTGRES_HOST
        export KONG_PG_PORT=$POSTGRES_PORT
        export KONG_PG_DATABASE=$POSTGRES_DATABASE
    elif [[ "$DATABASE" == "cassandra" ]]; then
        echo "Dropping Cassandra keyspace '$CASSANDRA_KEYSPACE'"
        cqlsh --cqlversion=3.4.2 \
            -e "DROP KEYSPACE $CASSANDRA_KEYSPACE" \
            $CASSANDRA_CONTACT_POINT \
            $CASSANDRA_PORT
        if [[ "$?" -ne 0 && "$?" -ne 2 ]]; then
            show_warning "cqlsh drop keyspace failed with: $?"
        fi

        export KONG_DATABASE=$DATABASE
        export KONG_CASSANDRA_CONTACT_POINTS=$CASSANDRA_CONTACT_POINT
        export KONG_CASSANDRA_PORT=$CASSANDRA_PORT
        export KONG_CASSANDRA_KEYSPACE=$CASSANDRA_KEYSPACE
    fi

    # Install Kong Base version
    install_kong $base_version $base_repo_dir

    pushd $base_repo_dir
        echo "Running $base_version migrations"
        bin/kong migrations up --vv \
            || show_error "Kong base version migration failed with: $?"

        echo "Starting Kong $base_version"
        bin/kong start --vv \
            || show_error "Kong base start failed with: $?"

        echo "Populating Kong $base_version"
        resty $root/util/populate.lua http://$ADMIN_LISTEN $test_suite_dir \
            || show_error "populate.lua script faild with: $?"

        run_lua_script "proxy base version" "proxy_base_test.lua"

        bin/kong stop --vv \
            || show_error "failed to stop Kong with: $?"

        echo "$base_version instance ready, stopping Kong"
    popd

    # Install Kong target version
    install_kong $target_version $target_repo_dir

    #######
    # TESTS
    #######

    pushd $target_repo_dir
        # TEST: run migrations between base and target version
        echo
        echo $test_sep "TEST migrations up: run $target_version migrations"
        bin/kong migrations up --v >&5 2>&6 \
            || failed_test "'kong migrations up' failed with: $?"
        echo "OK"

        # TEST: start target version
        echo
        echo $test_sep "TEST kong start: $target_version starts (migrated)"
        bin/kong start --v >&5 2>&6 \
            || failed_test "'kong start' failed with: $?"
        echo "OK"
    popd

    # TEST: run admin_test.lua if exists
    run_lua_script "admin" "admin_test.lua"

    # TEST: run proxy_test.lua if exists
    run_lua_script "proxy target version" "proxy_test.lua"

    echo
    echo "Success"

    cleanup
}

parse_version_arg() {
    if [[ $1 =~ : ]]; then
        ret1=`builtin echo $1 | cut -d':' -f2` # version
        ret2=`builtin echo $1 | cut -d':' -f1` # repo
    else
        ret1=$1
    fi
}

clone_or_pull_repo() {
    repo=$1

    if [[ ! -d "$cache_dir/$repo" ]]; then
        pushd $cache_dir
            echo "Cloning git@github.com:kong/$repo.git"
            ssh-agent bash -c "ssh-add $ssh_key && \
                git clone git@github.com:kong/$repo.git $repo" \
                    || show_error "git clone failed with: $?"
        popd
    else
        pushd $cache_dir/$repo
            echo "Pulling git@github.com:kong/$repo.git"
            git pull
        popd
    fi
}

prepare_repo() {
    repo=$1
    version=$2
    tmp_repo_name=$repo-`builtin echo $version | sed 's/\//_/g'`

    pushd $tmp_dir
        cp -R $cache_dir/$repo $tmp_repo_name \
            || show_error "cp failed with: $?"
        pushd $tmp_repo_name
           git checkout $version \
               || { co_exit=$?; rm -rf $tmp_repo_name; show_error "git checkout to '$version' failed with: $co_exit"; }
        popd
    popd

    ret1=$tmp_dir/$tmp_repo_name
}

install_kong() {
    version=$1
    dir=$2

    echo
    echo "Installing Kong version $version"

    pushd $dir
        major_version=`builtin echo $version | sed 's/\.[0-9]*$//g'`
        if [[ -f "$root/patches/kong-$version-no_openresty_version_check.patch" ]]; then
            echo "Applying kong-$version-no_openresty_version_check patch to Kong $version"
            patch -p1 < $root/patches/kong-$version-no_openresty_version_check.patch \
                || show_error "failed to apply patch: $?"
        elif [[ -f "$root/patches/kong-$major_version-no_openresty_version_check.patch" ]]; then
            echo "Applying kong-$major_version-no_openresty_version_check patch to Kong $version"
            patch -p1 < $root/patches/kong-$major_version-no_openresty_version_check.patch \
                || show_error "failed to apply patch: $?"
        else
            echo "No kong-no_openresty_version_check patch to apply to Kong $version"
        fi

        echo "Installing Kong..."
        make -k dev \
            || show_error "installing Kong failed with: $?"
    popd
}

run_lua_script() {
    local name="$1"
    local filename="$2"

    echo $test_sep "TEST $name script"
    if [[ -f "$test_suite_dir/$filename" ]]; then
      resty -e "package.path = package.path .. ';' .. '$root/?.lua'" \
            "$test_suite_dir/$filename" \
            http://$ADMIN_LISTEN \
            http://$PROXY_LISTEN \
            http://$ADMIN_LISTEN_SSL \
            http://$PROXY_LISTEN_SSL >&5 \
            || failed_test "$name test script failed with: $?"
        echo "OK"
    else
        echo "SKIP"
    fi
}

cleanup() {
    kill `cat $KONG_PREFIX/pids/nginx.pid 2>/dev/null` 2>/dev/null
}

show_help() {
    echo "Usage: $0 [options...] --base <base> --target <target> TEST_SUITE"
    echo
    echo "Arguments:"
    echo "  -b,--base          base version"
    echo "  -t,--target        target version"
    echo "  TEST_SUITE         path to test suite"
    echo
    echo "Options:"
    echo "  -d,--database      database (default: postgres)"
    echo "  -f,--force         cleanup cache and force git clone"
    echo "  --ssh-key          ssh key to use when cloning repositories"
    echo
}

wrong_usage() {
    echo_err "Invalid usage: $1"
    echo_err
    show_help
    exit 1
}

failed_test() {
    cleanup
    echo_err "Failed: $1"
    builtin echo "  displaying last lines of: $log_file" >&6
    builtin echo "  -----------------------------------" >&6
    grep ERROR -A50 $log_file >&6 || tail $log_file >&6
    echo_err
    exit 1
}

show_warning() {
    echo_err "Warning: $1"
}


show_error() {
    cleanup
    echo_err "Error: $1"
    builtin echo "  displaying last lines of: $log_file" >&6
    builtin echo "  -----------------------------------" >&6
    grep ERROR -A50  $log_file >&6 || tail $log_file >&6
    echo_err
    exit 1
}

echo() {
    # we log to our log file and to our original stdout
    builtin echo "$@"
    builtin echo "$@" >&5
}

echo_err() {
    builtin echo "$@"
    builtin echo "$@" >&6
}

pushd() { builtin pushd $1 > /dev/null; }
popd() { builtin popd > /dev/null; }

main "$@"

