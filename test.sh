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
export KONG_NGINX_WORKER_PROCESSES=1

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

    if [[ ! -d "$test_suite_dir/before" ]]; then
        wrong_usage "TEST_SUITE does not contain migration data"
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
        msg "Dropping PostgreSQL database '$POSTGRES_DATABASE'"
        dropdb -U postgres -h $POSTGRES_HOST -p $POSTGRES_PORT $POSTGRES_DATABASE \
             || show_warning "dropdb failed with: $?"
        createdb -U postgres -h $POSTGRES_HOST -p $POSTGRES_PORT $POSTGRES_DATABASE \
            || show_error "createdb failed with: $?"

        export KONG_DATABASE=$DATABASE
        export KONG_PG_HOST=$POSTGRES_HOST
        export KONG_PG_PORT=$POSTGRES_PORT
        export KONG_PG_DATABASE=$POSTGRES_DATABASE
    elif [[ "$DATABASE" == "cassandra" ]]; then
        msg "Dropping Cassandra keyspace '$CASSANDRA_KEYSPACE'"
        cqlsh \
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
        set_env_vars
        msg "Running $base_version migrations"
        bin/kong migrations up --vv \
            || show_error "Kong base version migration failed with: $?"

        msg "Starting Kong $base_version"
        bin/kong start --vv \
            || show_error "Kong base start failed with: $?"
    popd

    msg "--------------------------------------------------"
    msg "Running requests against Kong $base_version"
    msg "--------------------------------------------------"

    rm -f responses.dump

    for file in $test_suite_dir/before/*.json
    do
        run_json_commands "before/$(basename "$file")" "$file"
    done

    pushd $base_repo_dir
        bin/kong stop --vv \
            || show_error "failed to stop Kong with: $?"

        msg "$base_version instance ready, stopping Kong"
    popd

    # Install Kong target version
    install_kong $target_version $target_repo_dir

    #######
    # TESTS
    #######

    pushd $target_repo_dir
        set_env_vars
        # TEST: run migrations between base and target version
        bin/kong migrations list > $tmp_dir/base.migrations
        msg_test "TEST migrations up: run $target_version migrations"
        bin/kong migrations up --v >&5 2>&6 \
            || failed_test "'kong migrations up' failed with: $?"
        msg_green "OK"
        bin/kong migrations list > $tmp_dir/target.migrations

        $root/scripts/diff_migrations $tmp_dir/base.migrations $tmp_dir/target.migrations >&5

        # TEST: start target version
        msg_test "TEST kong start: $target_version starts (migrated)"
        bin/kong start --v >&5 2>&6 \
            || failed_test "'kong start' failed with: $?"
        msg_green "OK"
    popd

    msg "--------------------------------------------------"
    msg "Running requests against Kong $target_version"
    msg "--------------------------------------------------"

    for file in $test_suite_dir/after/*.json
    do
        run_json_commands "after/$(basename "$file")" "$file"
    done

    echo
    msg_green "*** Success ***"
    echo

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
            msg "Cloning git@github.com:kong/$repo.git"
            ssh-agent bash -c "ssh-add $ssh_key && \
                git clone git@github.com:kong/$repo.git $repo" \
                    || show_error "git clone failed with: $?"
        popd
    else
        pushd $cache_dir/$repo
            msg "Pulling git@github.com:kong/$repo.git"
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

set_env_vars() {
    if grep -q "proxy_listen_ssl" kong.conf.default; then
        export KONG_ADMIN_LISTEN="$ADMIN_LISTEN"
        export KONG_PROXY_LISTEN="$PROXY_LISTEN"
        export KONG_ADMIN_LISTEN_SSL="$ADMIN_LISTEN_SSL"
        export KONG_PROXY_LISTEN_SSL="$PROXY_LISTEN_SSL"
    else
        export KONG_ADMIN_LISTEN="$ADMIN_LISTEN, $ADMIN_LISTEN_SSL ssl"
        export KONG_PROXY_LISTEN="$PROXY_LISTEN, $PROXY_LISTEN_SSL ssl"
    fi
}

install_kong() {
    version=$1
    dir=$2

    echo
    msg "Installing Kong version $version"

    pushd $dir
        major_version=`builtin echo $version | sed 's/\.[0-9]*$//g'`
        if [[ -f "$root/patches/$base_repo-$version-no_openresty_version_check.patch" ]]; then
            msg "Applying $base_repo-$version-no_openresty_version_check patch to Kong $version"
            patch -p1 < $root/patches/$base_repo-$version-no_openresty_version_check.patch \
                || show_error "failed to apply patch: $?"
        elif [[ -f "$root/patches/$base_repo-$major_version-no_openresty_version_check.patch" ]]; then
            msg "Applying $base_repo-$major_version-no_openresty_version_check patch to Kong $version"
            patch -p1 < $root/patches/$base_repo-$major_version-no_openresty_version_check.patch \
                || show_error "failed to apply patch: $?"
        else
            msg "No $base_repo-no_openresty_version_check patch to apply to Kong $version"
        fi

        msg "Installing Kong..."
        make -k dev \
            || show_error "installing Kong failed with: $?"
    popd
}

run_json_commands() {
    local name="$1"
    local filepath="$2"

    # if filename contains database name, only run it for that database
    if [[ ("$filepath" =~ cassandra && "$DATABASE" != cassandra) ||
          ("$filepath" =~ postgres  && "$DATABASE" != postgres) ]]; then
        return
    fi

    msg_test "TEST $name script"
    if [[ -f $filepath ]]; then
      resty -e "package.path = package.path .. ';' .. '$root/?.lua'" \
            $root/util/json_commands_runner.lua \
            http://$ADMIN_LISTEN \
            http://$PROXY_LISTEN \
            http://$ADMIN_LISTEN_SSL \
            http://$PROXY_LISTEN_SSL \
            $filepath >&5 \
            || failed_test "$name json commands failed with: $?"
        msg_green "OK"
    else
        msg_yellow "SKIP"
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
    msg_red "Failed: $1"
    builtin echo "  displaying last lines of: $log_file" >&6
    builtin echo "  -----------------------------------" >&6
    grep ERROR -A50 $log_file >&6 || tail $log_file >&6
    echo_err
    exit 1
}

show_warning() {
    msg_yellow "Warning: $1"
}


show_error() {
    cleanup
    msg_red "Error: $1"
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

msg() {
    builtin echo -en "\033[1m" >&5
    echo "$@"
    builtin echo -en "\033[0m" >&5
}

msg_test() {
    builtin echo -en "\033[1;34m" >&5
    echo -n "===> "
    builtin echo -en "\033[1;36m" >&5
    echo "$@"
    builtin echo -en "\033[0m" >&5
}

msg_green() {
    builtin echo -en "\033[1;32m" >&5
    echo "$@"
    builtin echo -en "\033[0m" >&5
}

msg_yellow() {
    builtin echo -en "\033[1;33m" >&6
    echo_err "$@"
    builtin echo -en "\033[0m" >&6
}

msg_red() {
    builtin echo -en "\033[1;31m" >&6
    echo_err "$@"
    builtin echo -en "\033[0m" >&6
}

pushd() { builtin pushd $1 > /dev/null; }
popd() { builtin popd > /dev/null; }

main "$@"

