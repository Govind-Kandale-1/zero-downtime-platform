{{- define "app.backupScript" -}}
set -eu
if [ -z "${MIGRATION_DATABASE_URL:-}" ]; then
  echo "no database yet (secret app-env not created); nothing to back up"
  exit 0
fi
ts=$(date -u +%Y%m%dT%H%M%SZ)
out="/backups/${PREFIX}-${ts}"
pg_dump -Fc "$MIGRATION_DATABASE_URL" -f "${out}.dump"
if [ -n "$(psql "$MIGRATION_DATABASE_URL" -tAc "select to_regclass('public.items')")" ]; then
  psql "$MIGRATION_DATABASE_URL" -tA -F' ' -c "select count(*), md5(coalesce(string_agg(id::text || name, ',' order by id), '')) from items" > "${out}.counts"
else
  echo "0 none" > "${out}.counts"
fi
echo "wrote ${out}.dump ($(wc -c < "${out}.dump") bytes) counts: $(cat "${out}.counts")"
# Retention: keep the newest N dumps of this kind.
ls -1t /backups/${PREFIX}-*.dump | tail -n +$((RETAIN + 1)) | while read -r f; do rm -f "$f" "${f%.dump}.counts"; done
{{- end }}
{{- define "app.backupPod" -}}
restartPolicy: Never
automountServiceAccountToken: false
securityContext:
  runAsNonRoot: true
  runAsUser: 70
  runAsGroup: 70
  fsGroup: 70
  seccompProfile: { type: RuntimeDefault }
containers:
  - name: pg-dump
    image: {{ .root.Values.backup.image }}
    command: ["/bin/sh", "-c"]
    args:
      - |
        {{- include "app.backupScript" .root | nindent 8 }}
    env:
      - { name: PREFIX, value: {{ .prefix }} }
      - { name: RETAIN, value: {{ .root.Values.backup.retain | quote }} }
      - { name: HOME, value: /tmp }
    envFrom:
      - secretRef:
          name: app-env
          optional: true
    resources:
      requests: { cpu: 10m, memory: 32Mi }
      limits: { memory: 128Mi }
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: [ALL] }
    volumeMounts:
      - { name: backups, mountPath: /backups }
      - { name: tmp, mountPath: /tmp }
volumes:
  - name: backups
    persistentVolumeClaim:
      claimName: backups
  - name: tmp
    emptyDir: {}
{{- end }}
