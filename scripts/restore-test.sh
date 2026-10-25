#!/usr/bin/env bash
# Restore drill (evidence 04): proves a backup can actually be restored, and
# times it. Non-destructive: it restores into a throwaway CloudNativePG
# cluster next to the stack, never over the live database.
#
#   1. take a fresh backup with the stack's own CronJob (or --latest: newest dump)
#   2. create CNPG Cluster "restore-test" (1 instance) in the same namespace
#   3. a Job mounts the provider-layer volume "pg-backups" read-only, runs
#      pg_restore into the scratch cluster, and recomputes the row count + md5
#      that the backup job recorded next to the dump
#   4. print RESTORE PASS/FAIL with rows, md5 and the restore time; clean up
#
# Usage: restore-test.sh <namespace> [--latest] [--keep]
set -euo pipefail
# shellcheck source=scripts/lib/tools.sh
. "$(dirname "$0")/lib/tools.sh"
KUBECONFIG=${KUBECONFIG:-"$(repo_root)/.local/kubeconfig"}
export KUBECONFIG

ns=${1:?usage: restore-test.sh <namespace> [--latest] [--keep]}
shift
latest=false
keep=false
for a in "$@"; do
  case "$a" in
    --latest) latest=true ;;
    --keep) keep=true ;;
    *) die "unknown flag $a" ;;
  esac
done
name=restore-test

cleanup() {
  $keep && return
  kubectl -n "$ns" delete job "$name" --ignore-not-found --wait=false >/dev/null || true
  kubectl -n "$ns" delete cluster.postgresql.cnpg.io "$name" --ignore-not-found --wait=false >/dev/null || true
}
trap cleanup EXIT

# 1. The dump to restore. Empty means "the newest on the volume".
dump=""
if ! $latest; then
  job=backup-drill-$(date +%s)
  log "taking a fresh backup with cronjob/backup ($job)"
  kubectl -n "$ns" create job --from=cronjob/backup "$job" >/dev/null
  kubectl -n "$ns" wait --for=condition=complete "job/$job" --timeout=300s >/dev/null || die "backup job $job did not complete"
  out=$(kubectl -n "$ns" logs "job/$job")
  echo "$out"
  dump=$(printf '%s\n' "$out" | sed -n 's|^wrote \(/backups/[^ ]*\.dump\).*|\1|p')
  [ -n "$dump" ] || die "cannot find the dump path in the backup log"
  kubectl -n "$ns" delete job "$job" --wait=false >/dev/null
fi

# 2. A scratch database. The clock starts here: this is what a real restore
# has to do too (new instance, then data).
start=$(date +%s)
log "creating CNPG cluster $name"
kubectl apply -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $name
  namespace: $ns
  labels: { app.kubernetes.io/part-of: restore-drill }
spec:
  instances: 1
  imageName: $CNPG_POSTGRES_IMAGE
  storage: { size: 1Gi }
  resources: { requests: { cpu: 50m, memory: 128Mi }, limits: { memory: 256Mi } }
  bootstrap:
    initdb: { database: app, owner: app }
EOF
kubectl -n "$ns" wait --for=condition=Ready "cluster.postgresql.cnpg.io/$name" --timeout=300s >/dev/null \
  || die "scratch cluster $name never became Ready"
ready=$(date +%s)
log "cluster ready after $((ready - start)) s; restoring ${dump:-the newest dump}"

# 3. Restore and verify inside the cluster, from the backup volume. The Job
# runs the same check the backup job recorded, so equal output = same data.
kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $name
  namespace: $ns
  labels: { app.kubernetes.io/part-of: restore-drill }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        runAsGroup: 70
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: restore
          image: $POSTGRES_IMAGE
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              dump="\${DUMP:-\$(ls -1t /backups/*.dump | head -1)}"
              want=\$(cat "\${dump%.dump}.counts")
              pg_restore --no-owner --no-acl --exit-on-error -d "\$DB" "\$dump"
              got=\$(psql "\$DB" -tA -F' ' -c "select count(*), md5(coalesce(string_agg(id::text || name, ',' order by id), '')) from items")
              echo "dump=\$dump recorded=[\$want] restored=[\$got]"
              [ "\$got" = "\$want" ]
          env:
            - { name: DUMP, value: "$dump" }
            - { name: HOME, value: /tmp }
            - name: DB
              valueFrom: { secretKeyRef: { name: $name-app, key: uri } }
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits: { memory: 128Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: backups, mountPath: /backups, readOnly: true }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - name: backups
          persistentVolumeClaim: { claimName: pg-backups, readOnly: true }
        - name: tmp
          emptyDir: {}
EOF

deadline=$(($(date +%s) + 300))
while :; do
  s=$(kubectl -n "$ns" get job "$name" -o jsonpath='{.status.succeeded}/{.status.failed}')
  case "$s" in 1/*) break ;; */1) break ;; esac
  [ "$(date +%s)" -ge "$deadline" ] && die "restore job did not finish in 300 s"
  sleep 2
done
done_at=$(date +%s)
out=$(kubectl -n "$ns" logs "job/$name")
echo "$out"
line=$(printf '%s\n' "$out" | grep '^dump=' || true)
restored=$(printf '%s\n' "$line" | sed -n 's/.*restored=\[\([^]]*\)\].*/\1/p')
if [ "${s%%/*}" = 1 ] && [ -n "$restored" ]; then
  echo "RESTORE PASS $ns: rows=${restored%% *} md5=${restored#* } rto_seconds=$((done_at - start)) (new instance $((ready - start)) s + restore and verify $((done_at - ready)) s)"
else
  echo "RESTORE FAIL $ns: ${line:-restore job failed (see output above)}"
  exit 1
fi
