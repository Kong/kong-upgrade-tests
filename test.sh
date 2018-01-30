#!/usr/bin/env bash

# kong test instance configuration
DATABASE=postgres
ADMIN_LISTEN=127.0.0.1:18001
POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=5432
POSTGRES_DATABASE=kong_upgrade_path_tests

# constants
root=`pwd`
cache_dir=$root/cache
tmp_dir=$root/tmp
log_file=$root/err.log

# arguments
repo=kong
base_version=
target_version=
tmp_repo_name=
test_suite_dir=

# control variables
base_repo_dir=
target_repo_dir=


export KONG_PREFIX=$root/tmp/kong
export KONG_ADMIN_LISTEN=$ADMIN_LISTEN


main() {
    echo "" > $log_file

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
                ;;
            -b|--base)
                base_version=$2
                shift
                ;;
            -t|--target)
                target_version=$2
                shift
                ;;
            -r|--repo)
                repo=$2
                shift
                ;;
            -f|--force)
                rm -rf $cache_dir
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

    rm -rf $tmp_dir

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

    prepare_repo $base_version
    base_repo_dir=$tmp_dir/$tmp_repo_name

    prepare_repo $target_version
    target_repo_dir=$tmp_dir/$tmp_repo_name

    # setup database

    if [[ "$DATABASE" == "postgres" ]]; then
        dropdb -U postgres -h $POSTGRES_HOST -p $POSTGRES_PORT $POSTGRES_DATABASE \
            || show_error "dropdb failed with: $?"
        createdb -U postgres -h $POSTGRES_HOST -p $POSTGRES_PORT $POSTGRES_DATABASE >$log_file 2>&1 \
            || show_error "createdb failed with: $?"

        export KONG_DATABASE=$DATABASE
        export KONG_PG_HOST=$POSTGRES_HOST
        export KONG_PG_PORT=$POSTGRES_PORT
        export KONG_PG_DATABASE=$POSTGRES_DATABASE
    fi

    # Install Kong Base version

    pushd $base_repo_dir
        # hard-coded version, informative only (this patch should seldom need to change)
        patch -p1 < $root/patches/kong-0.12.1-no_openresty_version_check.patch >$log_file 2>&1\
            || show_error "failed to apply patch to Kong: $?"

        echo "Installing Kong base version ($base_version)"
        make dev >$log_file 2>&1 \
            || show_error "install Kong base version failed with: $?"

        echo "Running base version migrations"
        kong migrations up --vv >$log_file 2>&1 \
            || show_error "Kong base version migration failed with: $?"

        # start Kong and populate it
        echo "Starting Kong base version"
        kong start --vv >$log_file 2>&1 \
            || show_error "Kong base start failed with: $?"

        echo "Populating Kong base version..."
        resty $root/populate.lua http://$ADMIN_LISTEN $root/$test_suite_dir >$log_file 2>&1 \
            || show_error "populate.lua script faild with: $?"

        kong stop --vv >$log_file 2>&1 \
            || show_error "failed to stop Kong with: $?"

        echo "Base version ready, stopping Kong"
        echo
    popd

    pushd $target_repo_dir
        # hard-coded version, informative only (this patch should seldom need to change)
        patch -p1 < $root/patches/kong-0.12.1-no_openresty_version_check.patch >$log_file 2>&1 \
            || show_error "failed to apply patch to Kong: $?"

        echo "Installing Kong target version ($target_version)"
        make dev >$log_file 2>&1 \
            || show_error "install Kong target version failed with: $?"

        # TEST: run migrations between base and target version
        echo
        echo "TEST migrations up: run target version migrations"
        kong migrations up --v \
            || failed_test "'kong migrations up' failed with: $?"
        echo "TEST migrations up: OK"

        # TEST: start target version
        echo
        echo "TEST kong start: target version starts (migrated)"
        kong start --v \
            || failed_test "'kong start' failed with: $?"
        echo "TEST kong start: OK"
    popd

    echo
    echo "Success"

    cleanup
}

prepare_repo() {
    version=$1
    tmp_repo_name=$repo-$version

    mkdir -p $cache_dir $tmp_dir

    if [[ ! -d "$cache_dir/$repo" ]]; then
        pushd $cache_dir
            echo "cloning git@github.com:kong/$repo.git..."
            git clone git@github.com:kong/$repo.git $repo >$log_file 2>&1 \
                || show_error "git clone failed with: $?"
        popd
    else
        pushd $cache_dir/$repo
            git pull >$log_file 2>&1
        popd
    fi

    pushd $tmp_dir
        cp -R $cache_dir/$repo $tmp_repo_name >$log_file 2>&1
        pushd $tmp_repo_name
           git checkout $version >$log_file 2>&1 \
               || { co_exit=$?; rm -rf $tmp_repo_name; show_error "git checkout to '$version' failed with: $?"; }
        popd
    popd
}

cleanup() {
    kong stop >/dev/null 2>&1
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
    echo "  -d,--database      database"
    echo "  -r,--repo          repository"
    echo "  -f,--force         cleanup cache and force git clone"
    echo
}

wrong_usage() {
    echo "Invalid usage: $1"        >&2
    echo                            >&2
    show_help
    exit 1
}

failed_test() {
    cleanup
    echo "FAILED: $1"               >&2
    echo "  see logs at: $log_file" >&2
    echo                            >&2
    exit 1
}

show_error() {
    cleanup
    echo "Error: $1"                >&2
    echo "  see logs at: $log_file" >&2
    echo                            >&2
    exit 1
}

pushd() { builtin pushd $1 > /dev/null; }
popd() { builtin popd > /dev/null; }

main "$@"

