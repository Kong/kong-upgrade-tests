#!/usr/bin/env bash

./test.sh -d $DB -b kong:$SRC -t kong:$DST $TEST
