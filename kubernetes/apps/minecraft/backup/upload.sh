#!/bin/sh
set -eu

: "${BACKUP_DIR:?BACKUP_DIR is required}"
: "${BACKUP_PREFIX:?BACKUP_PREFIX is required}"
: "${GCS_BUCKET:?GCS_BUCKET is required}"

export LC_ALL=C

backup_file="$({
  find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.zip' -exec stat -c '%Y %n' {} \;
} | sort -rn | awk 'NR == 2 { sub(/^[^ ]+ /, ""); print; exit }')"

if [ -z "$backup_file" ]; then
  echo "No second-newest ZIP found in ${BACKUP_DIR}" >&2
  exit 1
fi

upload_date="$(TZ=Asia/Tokyo date +%F)"
backup_name="${backup_file##*/}"
object_name="${BACKUP_PREFIX}/${upload_date}__${backup_name}"

echo "Uploading ${backup_file} to gs://${GCS_BUCKET}/${object_name}"
rclone copyto \
  "$backup_file" \
  "gcs:${GCS_BUCKET}/${object_name}" \
  --no-check-dest \
  --retries 1 \
  --log-level INFO
