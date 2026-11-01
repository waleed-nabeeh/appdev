#!/bin/sh
set -eu
authfile=/credentials/registry/config.json
if [ ! -f "$authfile" ]; then authfile=/credentials/registry/.dockerconfigjson; fi
test -s "$authfile"
if [ "$MODE" = resolve ]; then
  input=/work/images.tsv
  : > /work/resolved.tsv
elif [ "$MODE" = recheck ]; then
  input=/work/resolved.tsv
else
  echo 'Unknown image resolution mode' >&2; exit 1
fi
while IFS="$(printf '\t')" read -r service repository tag expected; do
  digest=$(skopeo inspect --authfile "$authfile" --format '{{.Digest}}' "docker://$repository:$tag")
  [ "${#digest}" -eq 71 ] && printf '%s' "$digest" | grep -Eq '^sha256:[a-f0-9]{64}$' || { echo "Invalid digest for $service" >&2; exit 1; }
  if [ "$MODE" = recheck ]; then
    [ "$digest" = "$expected" ] || { echo "Tag moved during promotion: $repository:$tag" >&2; exit 1; }
  else
    printf '%s\t%s\t%s\t%s\n' "$service" "$repository" "$tag" "$digest" >> /work/resolved.tsv
    printf 'Resolved %s:%s -> %s\n' "$repository" "$tag" "$digest"
  fi
done < "$input"
