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
#
# schema_for fails, naming the example, when the example is not JSON, has no
# string `schema` field, names an unknown schema id, or names a schema id with
# no schema file. Callers assign its output first so `set -e` stops on it.
schema_for() {
  python3 - "$1" "$schemas" <<'PY'
import json, os, re, sys
example, schemas = sys.argv[1], sys.argv[2]
try:
    with open(example) as handle:
        document = json.load(handle)
except (OSError, ValueError) as error:
    sys.exit(f"{example}: not a JSON document: {error}")
schema_id = document.get("schema") if isinstance(document, dict) else None
if not isinstance(schema_id, str):
    sys.exit(f"{example}: no string 'schema' field")
match = re.fullmatch(r"keiro-dsl/service-topology/([0-9]+)", schema_id)
if not match:
    sys.exit(f"{example}: unknown schema id '{schema_id}'")
schema_file = os.path.join(schemas, f"keiro-dsl-service-topology-{match.group(1)}.schema.json")
if not os.path.isfile(schema_file):
    sys.exit(f"{example}: no schema file for '{schema_id}' ({schema_file})")
print(schema_file)
PY
}
examples=0
for example in "$goldens"/schema-examples/*.valid.json; do
  schema_file="$(schema_for "$example")"
  check-jsonschema --schemafile "$schema_file" "$example"
  examples=$((examples + 1))
done
# An invalid example passes only on a real schema violation. check-jsonschema
# exits 1 alike for a violation, an unparsable instance and a schema it cannot
# load, so read its `--output-format json` report instead (check-jsonschema
# 0.38.0): a violation is `"status": "fail"` with a non-empty `errors` list (each
# with `path` and `message`) and an empty `parse_errors` list. An unparsable
# instance has `errors: []` and a non-empty `parse_errors`; a schema that cannot
# be loaded prints no JSON report at all.
for example in "$goldens"/schema-examples/*.invalid.json; do
  schema_file="$(schema_for "$example")"
  report="$(check-jsonschema --output-format json --schemafile "$schema_file" "$example" 2>&1 || true)"
  if ! verdict="$(python3 -c '
import json, sys
try:
    report = json.loads(sys.argv[1])
except ValueError:
    sys.exit("check-jsonschema printed no JSON report: " + sys.argv[1].strip())
errors, parse_errors = report.get("errors") or [], report.get("parse_errors") or []
if report.get("status") == "ok":
    sys.exit("expected a schema violation, but it validated")
if parse_errors:
    sys.exit("the instance did not parse: " + "; ".join(e.get("message", "") for e in parse_errors))
if report.get("status") != "fail" or not errors:
    sys.exit("check-jsonschema failed without reporting a schema error")
print("; ".join(e["path"] + ": " + e["message"] for e in errors))
' "$report" 2>&1)"; then
    echo "$example: $verdict" >&2
    exit 1
  fi
  echo "rejected as expected -- $(basename "$example") ($verdict)"
  examples=$((examples + 1))
done
echo "topology schemas: $count golden document(s) valid, $examples compatibility example(s) as expected"
