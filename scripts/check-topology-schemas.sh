#!/usr/bin/env bash
# Validate every committed keiro-dsl service-topology golden document against
# the JSON Schema named by its own `schema` field
# (keiro-dsl/service-topology/N -> docs/user/schemas/keiro-dsl-service-topology-N.schema.json),
# after checking each schema against the JSON Schema metaschema.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
schemas="$root/docs/user/schemas"
goldens="$root/keiro-dsl/test/fixtures/topology"

shopt -s nullglob
schema_files=("$schemas"/keiro-dsl-service-topology-*.schema.json)
if [ "${#schema_files[@]}" -eq 0 ]; then
  echo "no topology schemas under $schemas" >&2
  exit 1
fi
check-jsonschema --check-metaschema "${schema_files[@]}"

count=0
while IFS= read -r -d '' golden; do
  schema_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["schema"])' "$golden")"
  case "$schema_id" in
    keiro-dsl/service-topology/[0-9]*) ;;
    *) echo "$golden: unknown schema id '$schema_id'" >&2; exit 1 ;;
  esac
  schema_file="$schemas/keiro-dsl-service-topology-${schema_id##*/}.schema.json"
  if [ ! -f "$schema_file" ]; then
    echo "$golden: no schema file for '$schema_id' ($schema_file)" >&2
    exit 1
  fi
  check-jsonschema --schemafile "$schema_file" "$golden"
  count=$((count + 1))
done < <(find "$goldens" -name '*.topology.golden.json' -print0 | sort -z)

if [ "$count" -eq 0 ]; then
  echo "no topology golden documents under $goldens" >&2
  exit 1
fi

# Compatibility examples: *.valid.json must validate (for example an older
# document without optional fields added later) and *.invalid.json must not.
schema_for() {
  local id
  id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["schema"])' "$1")"
  echo "$schemas/keiro-dsl-service-topology-${id##*/}.schema.json"
}
examples=0
for example in "$goldens"/schema-examples/*.valid.json; do
  check-jsonschema --schemafile "$(schema_for "$example")" "$example"
  examples=$((examples + 1))
done
for example in "$goldens"/schema-examples/*.invalid.json; do
  if check-jsonschema --schemafile "$(schema_for "$example")" "$example" > /dev/null 2>&1; then
    echo "$example: expected a schema violation, but it validated" >&2
    exit 1
  fi
  echo "rejected as expected -- $(basename "$example")"
  examples=$((examples + 1))
done
echo "topology schemas: $count golden document(s) valid, $examples compatibility example(s) as expected"
