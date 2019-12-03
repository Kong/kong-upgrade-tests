```
                            _,-}}-._
                           /\   }  /\
                          _|(O\_ _/O)
                        _|/  (__''__)
                      _|\/    WVVVVW    tasty vagrant!
                     \ _\     \MMMM/_
                   _|\_\     _ '---; \_
              /\   \ _\/      \_   /   \
             / (    _\/     \   \  |'VVV
            (  '-,._\_.(      'VVV /
             \         /   _) /   _)
              '....--''\__vvv)\__vvv)      ldb

                      Gojira (Godzilla)

Usage: gojira action [options...]

Options:
  -t,  --tag            git tag to mount kong on (default: master)
  -p,  --prefix         prefix to use for namespacing
  -k,  --kong           PATH for a kong folder, will ignore tag
  -n,  --network        use network with provided name
  -r,  --repo           repo to clone kong from
  -pp, --port           expose a port for a kong container
  -v,  --volume         add a volume to kong container
  --image               image to use for kong
  --cassandra           use cassandra
  --alone               do not spin up any db
  --redis-cluster       run redis in cluster mode
  --host                specify hostname for kong container
  --git-https           use https to clone repos
  -V,  --verbose        echo every command that gets executed
  -h,  --help           display this help

Commands:
  up            start a kong. if no -k path is specified, it will download
                kong-ee on $GOJIRA_KONGS folder and checkouts the -t tag.
                also fires up a postgres database .with it. for free.

  down          bring down the docker-compose thingie running in -t tag.
                remove it, nuke it from space. something went wrong, and you
                want a clear start or a less buggy tool to use.

  build         build a docker image with the specified VERSIONS

  run           run a command on a running container

  shell         get a shell on a running container

  cd            cd into a kong-ee prefix repo

  image         show current gojira image

  images        list gojira images

  ps            list running prefixes

  ls            list stored prefixes in $GOJIRA_KONGS

  snapshot      make a snapshot of a running gojira

  compose       alias for docker-compose, try: gojira compose help

  roar          make gojira go all gawo wowo

  logs          follow container logs

  nuke          remove all running gojiras

```

# gojira

gojira comes from far away to put an end to `vagrant up`, `vagrant destroy` and
`vagrant wait ten hours`.

Spin up as many kong-ee instances as you want. On different commits at the same
time. With different openssl, openresty and luarocks versions. Run a shell
inside of the containers, make kong roar. Make kong fail, cd into the repo, fix
it. Make kong start again. Commit it. Push it, ship it!


## Installation

gojira depends on docker (18.09.02) and docker-compose (1.23.2). As usual, the
most recent, the better.

> Note you need `~/.local/bin` on your `$PATH`.

```
PATH=$PATH:~/.local/bin
git clone git@github.com:Kong/kong-gojira.git
mkdir -p ~/.local/bin
ln -s $(realpath kong-gojira/gojira.sh) ~/.local/bin/gojira
```

### Additional for OS X

```
brew install coreutils
```


## Usage

For the time being, we have a [guide].
Also, a [vagrant to gojira guide].

[guide]: doc/manual.md
[vagrant to gojira guide]: doc/vagrant.md

## Environment variables

Certain behaviours of gojira can be tamed by using the following environment
variables.

### GOJIRA_REPO

> default: `kong-ee`

Default repository to clone from.

### GOJIRA_TAG

> default: `master`

Default tag to clone from `GOJIRA_REPO` when no `-t` has been provided


### GOJIRA_KONGS

> default: `~/.gojira-kongs`

Path where prefixes are stored


### GOJIRA_HOME

> default: `${GOJIRA_KONGS}/.gojira-home`

Path to the shared home between gojiras


### GOJIRA_IMAGE

Instead of building an image automatically, force this image to be used. [Docs]

[Docs]: doc/manual.md

### GOJIRA_GIT_HTTPS

> default: `0` (off)

Use https instead of ssh for cloning `GOJIRA_REPO`


### GOJIRA_DETECT_LOCAL

> default: `0` (off)

Detects if the current path is a kong repository, providing an automatic `-k`
flag. [Docs]

[Docs]: doc/manual.md#detect-kong-in-path

### GOJIRA_PIN_LOCAL_TAG

> default: `1` (on)

When using a local path (-k or auto), it will always generate the same gojira
prefix based on the md5 of the path. [Docs]

[Docs]: doc/manual.md#detect-kong-in-path


### GOJIRA_USE_SNAPSHOT

> default: `0` (off)

Try to use an automatic snapshot when available. [Docs]

[Docs]: doc/manual.md#using-snapshots-to-store-the-state-of-a-running-container
