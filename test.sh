#!/usr/bin/env bash
. ./semver.sh

set -x

# kong test instance configuration
DATABASE=postgres

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
base_host=base_kong
target_host=target_kong
test_suite_dir=
ssh_key=$HOME/.ssh/id_rsa
patches_branch=master

# control variables
keep=0
rebuild=0
ret1=
ret2=
force_migrating=0

export KONG_NGINX_WORKER_PROCESSES=1
export GOJIRA_KONGS=$cache_dir

GOJIRA_SETTINGS=(
  "--network test-upgrade"
  "--volume $root:/mig_tool"
)

# clear log file for this run
echo "" > $log_file

# save original stdout and stderr fds
exec 5<&1
exec 6<&2
## our log file is stdout and stderr
exec 1>$log_file 2>&1

main() {
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
            -p|--patches)
                patches_branch=$2
                shift
                ;;
            -m|--force-migrating)
                force_migrating=1
                ;;
            -f|--force-git-clone)
                rm -rf $cache_dir
                ;;
            -k|--keep)
                keep=1
                ;;
            --ssh-key)
                ssh_key=$2
                shift
                ;;
            --rebuild)
                rebuild=1
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

    if hash realpath ; then
        test_suite_dir=$(realpath $test_suite_dir)
    else
        test_suite_dir=$(readlink -f $test_suite_dir)
    fi

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

    if ! [[ "$keep" = "1" ]]; then
        rm -rf $tmp_dir
    fi
    mkdir -p $cache_dir $tmp_dir

    has_new_migrations $base_repo $base_version
    local base_has_new_migrations=$ret1

    has_new_migrations $target_repo $target_version
    local target_has_new_migrations=$ret1

    install_kong $base_repo $base_version
    image=$(b_gojira snapshot?)

    if [[ "$DATABASE" == "postgres" ]]; then
        b_gojira up --image $image
    elif [[ "$DATABASE" == "cassandra" ]]; then
        b_gojira up --image $image --cassandra
    fi

    msg "Waiting for $DATABASE"
    local iid=$(b_gojira compose ps -q db)
    unset healthy
    while [[ -z $healthy ]]; do
      healthy=$(docker inspect $iid | grep healthy)
      sleep 0.5
    done

    msg "Running $base_version migrations"
    if [[ $base_has_new_migrations == 0 ]]; then
      b_gojira run bin/kong migrations bootstrap --vv \
          || show_error "Base kong migrations bootstrap failed with: $?"
    fi

    b_gojira run bin/kong migrations up --vv \
        || show_error "Base kong migrations up failed with: $?"

    if [[ $base_has_new_migrations == 0 ]]; then
      b_gojira run bin/kong migrations finish --vv \
          || show_error "Base kong migrations finish failed with: $?"
    fi

    msg "Starting Kong $base_version (first node)"
    b_gojira run bin/kong start --vv \
        || show_error "Kong base start (first node) failed with: $?"

    msg "--------------------------------------------------"
    msg "Running requests against Kong $base_version"
    msg "--------------------------------------------------"

    rm -f responses.dump

    for file in $test_suite_dir/before/*.json
    do
        run_json_commands "before/$(basename "$file")" "$file"
    done

    install_kong $target_repo $target_version
    image=$(t_gojira snapshot?)

    if [[ "$DATABASE" == "postgres" ]]; then
        t_gojira up --image $image --alone
    elif [[ "$DATABASE" == "cassandra" ]]; then
        KONG_DATABASE=cassandra t_gojira up --image $image --alone
    fi

    #######
    # TESTS
    #######

    b_gojira run bin/kong migrations list > $tmp_dir/base.migrations

    msg_test "TEST migrations up: run $target_version migrations"
    t_gojira run kong migrations up --v >&5 2>&6 \
        || failed_test "'kong migrations up' failed with: $?"
    t_gojira run kong migrations list >&5 2>&6
    msg_green "OK"
    t_gojira run kong migrations list > $tmp_dir/target.migrations

    $root/scripts/diff_migrations $tmp_dir/base.migrations $tmp_dir/target.migrations >&5

    msg_test "TEST kong start (second node): $target_version starts (migrated)"
    t_gojira run kong start --v >&5 2>&6 \
        || failed_test "'kong start (second node)' failed with: $?"
    msg_green "OK"

    if [[ ("$target_has_new_migrations" -eq 0) || ("$force_migrating" -eq 1) ]]; then
        msg "------------------------------------------------------"
        msg "Running 'migrating' requests against Kong $target_version"
        msg "------------------------------------------------------"

        for file in $test_suite_dir/migrating/*.json
        do
            run_json_commands "migrating/$(basename "$file")" "$file"
        done

        echo
        msg_green "*** Success ***"
        echo

        b_gojira run kong stop --vv \
            || show_error "failed to stop Kong (first node) with: $?"

        #TEST: finish pending migrations
        t_gojira run kong migrations finish --v >&5 2>&6 \
          || failed_test "'kong migrations finish' failed with: $?"
        msg_green "OK"
    fi

    msg "------------------------------------------------------"
    msg "Running 'after' requests against Kong $target_version"
    msg "------------------------------------------------------"

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

b_gojira() {
  run_gojira $base_repo $base_version $base_host $@
}

t_gojira() {
  run_gojira $target_repo $target_version $target_host $@
}

run_gojira() {
  local repo=$1 ; shift
  local version=$1 ; shift
  local host=$1 ; shift
  local action=$1 ; shift
  local args=$@
  ./kong-gojira/gojira.sh $action -V ${GOJIRA_SETTINGS[*]} --repo $repo -t $version --host $host $@
}

has_new_migrations() {
  local repo=$1
  local version=$2
  case $repo in
    kong-ee)
      # Strip release/ from tag
      version=$(builtin echo $version | sed -e "s/release\///")

      if [[ "$version" = "master" ]] || [[ "$version" =~ "/" ]]; then
        ret1=0
        return
      fi
      ee_semverGT $version 0.34.999 5>/dev/null
      ret1=$?
      ;;
    kong)
      if [[ "$version" = "next" ]] || [[ "$version" =~ "/" ]]; then
        ret1=0
        return
      fi
      semverGT $version 0.14.1 5>/dev/null
      ret1=$?
      ;;
  esac
}

install_kong() {
    local repo=$1
    local version=$2
    local image

    if ! [[ "$rebuild" = "1" ]]; then
      image=$(./kong-gojira/gojira.sh snapshot? --repo $repo -t $version)

      if [[ ! -z $image ]]; then
          msg "Found dev build image $image, not going to install"
          return
      fi
      image=$(./kong-gojira/gojira.sh image? --repo $repo -t $version)
    fi

    msg "Installing Kong version $version"
    if [[ -z $image ]]; then
        # Do build!
        msg "Building base dependencies for $repo $version"
        ./kong-gojira/gojira.sh build -V --repo $repo -t $version
        image=$(./kong-gojira/gojira.sh image -V --repo $repo -t $version)
    fi

    ./kong-gojira/gojira.sh up --repo $repo -t $version --alone --image $image
    ./kong-gojira/gojira.sh run --repo $repo -t $version make dev || exit 1
    ./kong-gojira/gojira.sh snapshot --repo $repo -t $version
    ./kong-gojira/gojira.sh down --repo $repo -t $version
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
      l_filepath=$(echo $filepath | sed "s/${root////\\/}//")
      b_gojira run - <(cat << EOF
        export ADMIN_LISTEN=$base_host:8001
        export PROXY_LISTEN=$base_host:8000
        export ADMIN_LISTEN_SSL=$base_host:8444
        export PROXY_LISTEN_SSL=$base_host:8443

        export ADMIN_LISTEN_2=$target_host:8001
        export PROXY_LISTEN_2=$target_host:8000
        export ADMIN_LISTEN_SSL_2=$target_host:8444
        export PROXY_LISTEN_SSL_2=$target_host:8443

        export POSTGRES_HOST=db
        export POSTGRES_PORT=5432
        export POSTGRES_DATABASE=kong

        export CASSANDRA_CONTACT_POINT=db
        export CASSANDRA_PORT=9042
        export CASSANDRA_KEYSPACE=kong
        resty -e "package.path = package.path .. ';' .. '/mig_tool/?.lua'" \
              --shdict="cassandra 1m"                                      \
              /mig_tool/util/json_commands_runner.lua /mig_tool/$l_filepath
EOF
      ) >&5 || failed_test "$name json commands failed with: $?"
        msg_green "OK"
    else
        msg_yellow "SKIP"
    fi
}

cleanup() {
    b_gojira down
    t_gojira down
}

show_help() {
    echo "Usage: $0 [options...] --base <base> --target <target> TEST_SUITE"
    echo
    echo "Arguments:"
    echo "  -b,--base            base version"
    echo "  -t,--target          target version"
    echo "  TEST_SUITE           path to test suite"
    echo
    echo "Options:"
    echo "  -d,--database        database (default: postgres)"
    echo "  -p,--patches         Kong/openresty-patches branch to use (default: master)"
    echo "  -f,--force-git-clone cleanup cache and force git clone"
    echo "  -m,--force-migrating run the migrating specs (needed on non-semantic-versioned tags)"
    echo "  -k,--keep            do not compile and clone repositories from scratch"
    echo "                       (useful when running multiple tests between same base and target version)"
    echo "  --rebuild            force rebuilding of gojira images"
    echo "  --ssh-key            ssh key to use when cloning repositories"
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
