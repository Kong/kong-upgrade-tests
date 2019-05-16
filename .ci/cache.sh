#!/usr/bin/env bash

set -e

action=$1
repotag=$2
cache_folder=$3

repo=$(echo $repotag | tr ":" " " | awk '{print $1}')
tag=$( echo $repotag | tr ":" " " | awk '{print $2}')
image=$(gojira image --repo $repo -t $tag)
dest=$cache_folder/$image.tgz

mkdir -p $cache_folder
mkdir -p /var/lib/docker/tmp/

case $action in
    save)
        if [[ -f $dest ]]; then
            echo "$image is already cached"
        else
            echo "Storing $image to $dest"
            docker save $image | gzip -c > $dest
        fi
        ;;
    load)
        if [[ -f $dest ]]; then
            echo "loading $image"
            docker load -i $dest
        else
            echo "$dest not found"
        fi
        ;;
esac

set +e
