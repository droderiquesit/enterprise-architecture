#!/bin/sh
# Helm post-renderer of helm_release.datadog (modules/kubernetes): adds the `dsv-fetch-install` init container to the
# node Agent DaemonSet, the Cluster Agent Deployment and the cluster-checks runner Deployment. The datadog chart has no
# hook for extra init containers (3.253.2: only its own init-volume / init-config / seccomp init containers).
#
# The init container runs the dsv-fetch image (static Go binary, no shell, no Python) as
#   /opt/dsv-fetch/dsv-fetch install --dest /dsv-fetch-out/dsv-fetch
# which copies the binary into the pod's in-memory emptyDir "dsv-fetch" with mode 0500. It runs as uid 0 - the user of
# every Datadog container of the chart (Agent, Cluster Agent, runners) - so the file is owned by the Agent user with no
# group/other rights, which is what the Agent requires of secret_backend_command. No capability, no write outside the
# emptyDir, read-only root filesystem.
#
# Usage (helm provider postrender): sh dsv-fetch-init.sh --image <registry>/<repo>@sha256:<digest> --expect <n>
#   --expect: number of workloads that must receive the init container (fails the render otherwise, e.g. after a
#             chart change of the initContainers layout).
# Input/output: the rendered manifests on stdin/stdout (helm post-renderer protocol). POSIX sh + awk only.
set -eu
image=""
expect=""
volume="dsv-fetch"
while [ $# -gt 0 ]; do
  case "$1" in
    --image) image="$2"; shift 2 ;;
    --expect) expect="$2"; shift 2 ;;
    --volume) volume="$2"; shift 2 ;;
    *) echo "dsv-fetch-init: unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$image" in
  *@sha256:*) ;;
  *) echo "dsv-fetch-init: --image must be digest-pinned (<registry>/<repo>@sha256:<digest>)" >&2; exit 2 ;;
esac
case "$expect" in
  ''|*[!0-9]*) echo "dsv-fetch-init: --expect <n> required" >&2; exit 2 ;;
esac

exec awk -v image="$image" -v expect="$expect" -v vol="$volume" '
  /^---/ { target = 0 }
  /^# Source: / { target = ($3 ~ /\/templates\/(daemonset|cluster-agent-deployment|agent-clusterchecks-deployment)\.yaml$/) }
  { print }
  target && /^      initContainers:[ ]*$/ {
    print "      - name: dsv-fetch-install"
    print "        image: \"" image "\""
    print "        imagePullPolicy: IfNotPresent"
    print "        command: [\"/opt/dsv-fetch/dsv-fetch\", \"install\", \"--dest\", \"/dsv-fetch-out/dsv-fetch\"]"
    print "        securityContext:"
    print "          runAsUser: 0"
    print "          runAsGroup: 0"
    print "          runAsNonRoot: false"
    print "          allowPrivilegeEscalation: false"
    print "          readOnlyRootFilesystem: true"
    print "          capabilities: {drop: [ALL]}"
    print "          seccompProfile: {type: RuntimeDefault}"
    print "        resources:"
    print "          requests: {cpu: 10m, memory: 16Mi}"
    print "          limits: {memory: 64Mi}"
    print "        volumeMounts:"
    print "        - name: " vol
    print "          mountPath: /dsv-fetch-out"
    injected++
    target = 0
  }
  END {
    if (injected + 0 != expect + 0) {
      printf "dsv-fetch-init: injected the init container into %d workload(s), expected %d\n", injected, expect > "/dev/stderr"
      exit 1
    }
  }
'
