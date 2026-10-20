#!/usr/bin/env bash
# isolate.sh LOGDIR COMMAND [ARG...]
#
# Runs inside "unshare --mount" as root. The script logs to FKS_ROOT/var/log, but as a
# second line of defence the host's /var/log is replaced by an empty per-scenario
# directory in a private mount namespace; the harness checks it stays empty.
set -euo pipefail

logdir=${1:?usage: isolate.sh LOGDIR COMMAND [ARG...]}
shift
if [[ ! -d $logdir ]]; then
    echo "isolate.sh: $logdir is not a directory" >&2
    exit 125
fi
mount --bind "$logdir" /var/log
exec "$@"
