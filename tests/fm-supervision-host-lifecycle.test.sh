#!/usr/bin/env bash
# The lifecycle part of the supervision host suite: engine-error latch, engine
# bounding and reaping, restarted hosts, the park boundary, and host ownership.
# The cases and their fixture live in tests/fm-supervision-host.test.sh; the
# whole suite outgrew one portable serial CI shard, so this part runs as its own
# script on a separate runner (docs/fm-test-portable-shards.md).
set -u

exec bash "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host.test.sh" lifecycle
