#!/usr/bin/env bash
. ./semver.sh

# kong test instance configuration
DATABASE=postgres
prefix=servroot
OPENSSL_INSTALL_1=
OPENRESTY_INSTALL_1=
LUAROCKS_INSTALL_1=
export ADMIN_LISTEN=127.0.0.1:18001
export PROXY_LISTEN=127.0.0.1:18000
export ADMIN_LISTEN_SSL=127.0.0.1:18444
export PROXY_LISTEN_SSL=127.0.0.1:18443

prefix_2=servroot2
OPENSSL_INSTALL_2=
OPENRESTY_INSTALL_2=
LUAROCKS_INSTALL_2=
export ADMIN_LISTEN_2=127.0.0.1:19001
export PROXY_LISTEN_2=127.0.0.1:19000
export ADMIN_LISTEN_SSL_2=127.0.0.1:19444
export PROXY_LISTEN_SSL_2=127.0.0.1:19443

export POSTGRES_HOST=127.0.0.1
export POSTGRES_PORT=5432
export POSTGRES_DATABASE=kong_upgrade_path_tests

CASSANDRA_CONTACT_POINT=127.0.0.1
CASSANDRA_PORT=9042
CASSANDRA_KEYSPACE=kong_upgrade_path_tests

# constants
root=`pwd`
cache_dir=$root/cache
tmp_dir=$root/tmp
log_file=$root/run.log
cores=`nproc`
orig_path=$PATH

# arguments
base_version=
target_version=
base_repo=kong
target_repo=kong
test_suite_dir=
ssh_key=$HOME/.ssh/id_rsa
patches_branch=master

# control variables
keep=0
base_repo_dir=
target_repo_dir=
ret1=
ret2=
ret3=
ret4=
force_migrating=0

export KONG_NGINX_WORKER_PROCESSES=1

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

    if ! [[ "$keep" = "1" ]]; then
        rm -rf $tmp_dir
    fi
    mkdir -p $cache_dir $tmp_dir

    #kong prepare
    #kong health

    # Example:
    # ./test.sh -b 0.11.2 -t 0.12.1
    #
    #   creates the following structure:
    #
    #   ├── cache               -> long-lived cache of git repositories
    #   │   └── kong
    #   ├── err.log             -> error logs for this run
    #   ├── test.sh
    #   └── tmp
    #       ├── kong-0.11.2     -> short-lived checkout of 0.11.2
    #       └── kong-0.12.1     -> short-lived checkout of 0.12.1

    if [[ "$keep" = "0" ]]; then
        clone_or_pull_repo $base_repo
        if [[ "$base_repo" != "$target_repo" ]]; then
            clone_or_pull_repo $target_repo
        fi
    fi

    prepare_repo $base_repo $base_version
    base_repo_dir=$ret1

    semverLT $base_version 0.15.0 5>/dev/null
    nopatch=$((1 - $?))

    msg "installing base components for Kong $base_version"
    install_base_components $ret2 $ret3 $ret4 $nopatch
    OPENSSL_INSTALL_1=$ret1
    OPENRESTY_INSTALL_1=$ret2
    LUAROCKS_INSTALL_1=$ret3

    prepare_repo $target_repo $target_version
    target_repo_dir=$ret1

    semverLT $target_version 0.15.0 5>/dev/null
    nopatch=$((1 - $?))

    msg "installing base components for Kong $target_version"
    install_base_components $ret2 $ret3 $ret4 $nopatch
    OPENSSL_INSTALL_2=$ret1
    OPENRESTY_INSTALL_2=$ret2
    LUAROCKS_INSTALL_2=$ret3

    has_new_migrations $base_version
    local base_has_new_migrations=$ret1

    has_new_migrations $target_version
    local target_has_new_migrations=$ret1

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


    using_kong_node 1

    # Install Kong Base version
    install_kong $base_version $base_repo_dir

    pushd $base_repo_dir
        msg "Running $base_version migrations"

        if [[ $base_has_new_migrations == 0 ]]; then
          bin/kong migrations bootstrap --vv \
              || show_error "Base kong migrations bootstrap failed with: $?"
        fi

        bin/kong migrations up --vv \
            || show_error "Base kong migrations up failed with: $?"

        if [[ $base_has_new_migrations == 0 ]]; then
          bin/kong migrations finish --vv \
              || show_error "Base kong migrations finish failed with: $?"
        fi

        msg "Starting Kong $base_version (first node)"
        bin/kong start --vv \
            || show_error "Kong base start (first node) failed with: $?"
    popd

    msg "--------------------------------------------------"
    msg "Running requests against Kong $base_version"
    msg "--------------------------------------------------"

    rm -f responses.dump

    for file in $test_suite_dir/before/*.json
    do
        run_json_commands "before/$(basename "$file")" "$file"
    done

    using_kong_node 2

    # Install Kong target version
    install_kong $target_version $target_repo_dir

    #######
    # TESTS
    #######

    pushd $base_repo_dir
        using_kong_node 1

        bin/kong migrations list > $tmp_dir/base.migrations
    popd

    pushd $target_repo_dir
        using_kong_node 2

        # TEST: run migrations between base and target version
        msg_test "TEST migrations up: run $target_version migrations"
        bin/kong migrations up --v >&5 2>&6 \
            || failed_test "'kong migrations up' failed with: $?"
        bin/kong migrations list >&5 2>&6
        msg_green "OK"
        bin/kong migrations list > $tmp_dir/target.migrations

        $root/scripts/diff_migrations $tmp_dir/base.migrations $tmp_dir/target.migrations >&5

        msg_test "TEST kong start (second node): $target_version starts (migrated)"
        bin/kong start --v >&5 2>&6 \
            || failed_test "'kong start (second node)' failed with: $?"
        msg_green "OK"
    popd

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

        using_kong_node 1

        pushd $base_repo_dir
            unset KONG_PREFIX

            bin/kong stop -p="$prefix" --vv \
                || show_error "failed to stop Kong (first node) with: $?"
        popd

        using_kong_node 2

        pushd $target_repo_dir
            #TEST: finish pending migrations
            bin/kong migrations finish --v >&5 2>&6 \
              || failed_test "'kong migrations finish' failed with: $?"
            msg_green "OK"
        popd
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

has_new_migrations() {
  if [[ "$1" = "next" ]] || [[ "$1" =~ "/" ]]; then
    ret1=0
    return
  fi

  semverGT $1 0.14.1 5>/dev/null
  ret1=$?
}

install_base_components() {
  OPENRESTY=$1
  OPENSSL=$2
  LUAROCKS=$3
  NOPATCH=$4
  PREFIX=$5

  if [ "$NOPATCH" -eq "0" ]
  then
    msg "installing base components: OpenResty=$OPENRESTY, OpenSSL=$OPENSSL, LuaRocks=$LUAROCKS using $cores cores"
  else
    msg "installing base components: OpenResty (without patches)=$OPENRESTY, OpenSSL=$OPENSSL, LuaRocks=$LUAROCKS using $cores cores"
  fi

  OPENSSL_DOWNLOAD=$cache_dir/openssl-$OPENSSL
  OPENRESTY_PATCHES_DOWNLOAD=$cache_dir/openresty-patches
  OPENRESTY_DOWNLOAD=$cache_dir/openresty-$OPENRESTY
  LUAROCKS_DOWNLOAD=$cache_dir/luarocks-$LUAROCKS

  mkdir -p $OPENSSL_DOWNLOAD $OPENRESTY_DOWNLOAD $OPENRESTY_PATCHES_DOWNLOAD $LUAROCKS_DOWNLOAD

  if [ ! "$(ls -A $OPENSSL_DOWNLOAD)" ]; then
    pushd $cache_dir
      curl -s -S -L http://www.openssl.org/source/openssl-$OPENSSL.tar.gz | tar xz
    popd
  fi

  # OpenResty source is not cacheable, due to the fact that we may apply patches to them later
  rm -rf $OPENRESTY_DOWNLOAD
  pushd $cache_dir
    curl -s -S -L https://openresty.org/download/openresty-$OPENRESTY.tar.gz | tar xz
  popd

  if [ ! "$(ls -A $OPENRESTY_PATCHES_DOWNLOAD)" ]; then
    git clone https://github.com/kong/openresty-patches.git $OPENRESTY_PATCHES_DOWNLOAD
  fi

  pushd $OPENRESTY_PATCHES_DOWNLOAD
    git checkout -q $patches_branch || show_error "failed to checkout $patches_branch of openresty-patches, exit code: $?"
  popd

  if [ ! "$(ls -A $LUAROCKS_DOWNLOAD)" ]; then
    git clone -q https://github.com/keplerproject/luarocks.git $LUAROCKS_DOWNLOAD
  fi

  OPENSSL_INSTALL=$tmp_dir/openssl-$OPENSSL

  if [ "$NOPATCH" -eq "0" ]
  then
    OPENRESTY_INSTALL=$tmp_dir/openresty-$OPENRESTY-patch-$OPENSSL-$LUAROCKS
  else
    OPENRESTY_INSTALL=$tmp_dir/openresty-$OPENRESTY-nopatch-$OPENSSL-$LUAROCKS
  fi

  LUAROCKS_INSTALL=$OPENRESTY_INSTALL/luajit

  mkdir -p $OPENSSL_INSTALL $OPENRESTY_INSTALL

  if [ ! "$(ls -A $OPENSSL_INSTALL)" ]; then
    pushd $OPENSSL_DOWNLOAD
      msg "installing OpenSSL $OPENSSL..."
      ./config shared --prefix=$OPENSSL_INSTALL || show_error "failed to config OpenSSL"
      make -j1 || show_error "failed to compile OpenSSL" # OpenSSL can not be reliably compiled with parallel builds
      make install_sw || show_error "failed to install OpenSSL"
    popd
  fi

  if [ ! "$(ls -A $OPENRESTY_INSTALL)" ]; then
    OPENRESTY_OPTS=(
      "--prefix=$OPENRESTY_INSTALL"
      "--with-cc-opt='-I$OPENSSL_INSTALL/include'"
      "--with-ld-opt='-L$OPENSSL_INSTALL/lib -Wl,-rpath,$OPENSSL_INSTALL/lib'"
      "--with-pcre-jit"
      "--with-http_ssl_module"
      "--with-http_realip_module"
      "--with-http_stub_status_module"
      "--with-http_v2_module"
      "--with-stream_ssl_preread_module"
      "-j$cores"
    )

    pushd $OPENRESTY_DOWNLOAD
      if [ -d $OPENRESTY_PATCHES_DOWNLOAD/patches/$OPENRESTY ]; then
        msg "applying patches to OpenResty..."
        pushd bundle
          if [ "$NOPATCH" -eq "0" ]; then
            for patch_file in $(ls -1 $OPENRESTY_PATCHES_DOWNLOAD/patches/$OPENRESTY/*.patch); do
              echo "applying OpenResty patch $patch_file"
              patch -p1 < $patch_file || show_error "failed to apply OpenResty patches"
            done
          else
            echo "applying OpenResty patch $OPENRESTY_PATCHES_DOWNLOAD/patches/$OPENRESTY/nginx-1.13.6_06-remove-glibc-crypt_r-bug-workaround.patch"
            patch -p1 < $OPENRESTY_PATCHES_DOWNLOAD/patches/$OPENRESTY/nginx-1.13.6_06-remove-glibc-crypt_r-bug-workaround.patch || show_error "failed to apply OpenResty patches"
          fi
        popd
      fi

      msg "installing OpenResty $OPENRESTY..."
      eval ./configure ${OPENRESTY_OPTS[*]} || show_error "failed to configure OpenResty"

      make -j$cores > build.log || show_error "failed to compile OpenResty"
      make install || show_error "failed to install OpenResty"

      pushd $LUAROCKS_DOWNLOAD
        msg "Installing LuaRocks $LUAROCKS..."
        git checkout -q v$LUAROCKS
        ./configure \
          --prefix=$LUAROCKS_INSTALL \
          --lua-suffix=jit \
          --with-lua=$OPENRESTY_INSTALL/luajit \
          --with-lua-include=$OPENRESTY_INSTALL/luajit/include/luajit-2.1 \
          || show_error "failed to configure LuaRocks"
        make -j$cores build || show_error "failed to build LuaRocks"
        make install || show_error "failed to install LuaRocks"
      popd
    popd
  fi

  ret1=$OPENSSL_INSTALL
  ret2=$OPENRESTY_INSTALL
  ret3=$LUAROCKS_INSTALL

  msg_green "Done"
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
    ret1=$tmp_dir/$tmp_repo_name

    if [[ "$keep" = 1 ]]; then
      pushd $tmp_dir/$tmp_repo_name
        ret2=`grep OPENRESTY_BASE= .travis.yml | cut -d = -f 2`
        ret3=`grep OPENSSL= .travis.yml | cut -d = -f 2`
        ret4=`grep LUAROCKS= .travis.yml | cut -d = -f 2`
      popd

      return
    fi

    pushd $tmp_dir
      cp -R $cache_dir/$repo $tmp_repo_name \
        || show_error "cp failed with: $?"
      pushd $tmp_repo_name
        git checkout $version \
          || { co_exit=$?; rm -rf $tmp_repo_name; show_error "git checkout to '$version' failed with: $co_exit"; }
        ret2=`grep OPENRESTY_BASE= .travis.yml | cut -d = -f 2`
        ret3=`grep OPENSSL= .travis.yml | cut -d = -f 2`
        ret4=`grep LUAROCKS= .travis.yml | cut -d = -f 2`
      popd
    popd

}

set_env_vars() {
    pref=$1
    admin=$2
    proxy=$3
    admin_ssl=$4
    proxy_ssl=$5
    path=$6
    openssl_dir=$7

    export KONG_PREFIX="$pref"
    if grep -q "proxy_listen_ssl" kong.conf.default; then
        export KONG_ADMIN_LISTEN="$admin"
        export KONG_PROXY_LISTEN="$proxy"
        export KONG_ADMIN_LISTEN_SSL="$admin_ssl"
        export KONG_PROXY_LISTEN_SSL="$proxy_ssl"
    else
        export KONG_ADMIN_LISTEN="$admin, $admin_ssl ssl"
        export KONG_PROXY_LISTEN="$proxy, $proxy_ssl ssl"
    fi
    export PATH=$path
    export OPENSSL_DIR=$openssl_dir
}

using_kong_node() {
  if [[ "$1" = "1" ]]
  then
    set_env_vars $prefix $ADMIN_LISTEN $PROXY_LISTEN $ADMIN_LISTEN_SSL $PROXY_LISTEN_SSL \
      "$OPENSSL_INSTALL_1/bin:$OPENRESTY_INSTALL_1/bin:$OPENRESTY_INSTALL_1/nginx/sbin:$LUAROCKS_INSTALL_1/bin:$orig_path" \
      $OPENSSL_INSTALL_1
  else
    set_env_vars $prefix_2 $ADMIN_LISTEN_2 $PROXY_LISTEN_2 $ADMIN_LISTEN_SSL_2 $PROXY_LISTEN_SSL_2 \
      "$OPENSSL_INSTALL_2/bin:$OPENRESTY_INSTALL_2/bin:$OPENRESTY_INSTALL_2/nginx/sbin:$LUAROCKS_INSTALL_2/bin:$orig_path" \
      $OPENSSL_INSTALL_2
  fi
}

install_kong() {
    version=$1
    dir=$2

    echo
    msg "Installing Kong version $version"

    pushd $dir
        major_version=`builtin echo $version | sed 's/\.[0-9]*$//g'`

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
            $filepath >&5 \
            || failed_test "$name json commands failed with: $?"
        msg_green "OK"
    else
        msg_yellow "SKIP"
    fi
}

cleanup() {
    kill `cat $base_repo_dir/$prefix/pids/nginx.pid 2>/dev/null` 2>/dev/null
    kill `cat $base_repo_dir/$prefix_2/pids/nginx.pid 2>/dev/null` 2>/dev/null
    kill `cat $target_repo_dir/$prefix/pids/nginx.pid 2>/dev/null` 2>/dev/null
    kill `cat $target_repo_dir/$prefix_2/pids/nginx.pid 2>/dev/null` 2>/dev/null
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

