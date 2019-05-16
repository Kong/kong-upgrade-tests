* dev dependencies on image could be interesting
* add pg tools / supercharge?
* maybe it's better if they are on the same network by default ? It sucks to
  do it again. But it's not a problem if dev tools are there already IMHO
* gojira ps shows outside compose runnings
* add restart / more clever
* do something for logs
* add a snapshot action that snapshots a container and creates an image
  * would be even cooler if snapshot also stores DB state so you can share
    the image to reproduce a bug.
* same service name in network actually round robins between gojiras
* something something bash history
* vacuum action. Also investigate how much vacuum is left behind on normal kill
* maybe add an --rm flag or smth. Maybe --rm deletes .kong-gojiras/whatev too
* look at templating with https://github.com/tests-always-included/mo
* add openresty patches to setup env (look at kong-upgrade-tests)
* use getopts
* some tests do not pass on gojira
