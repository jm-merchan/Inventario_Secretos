#!/usr/bin/env bash
# Inventario de secretos KV v2: namespace, mount, path, metadatos y Secrets Sync.
#
# Uso:
#   SECRET_MAX_AGE_DAYS=90 ./scripts/vault_secret_inventory.sh
#   SECRET_MAX_AGE_DAYS=90 ./scripts/vault_secret_inventory.sh --output /tmp/vault/secret-inventory.csv
#   ./scripts/vault_secret_inventory.sh --max-age-days 30 --output inventario.csv
#
# La sesión de Vault es la del CLI: VAULT_ADDR, VAULT_TOKEN, VAULT_CACERT,
# VAULT_SKIP_VERIFY, el fichero de token o el agent. El script no fija otro login.
#
#   SECRET_MAX_AGE_DAYS o --max-age-days
#     Edad en días. older_than_threshold=true cuando la actividad más reciente
#     del secreto (creación o última versión) es anterior a ahora menos esos días.
#
# El script no configura Secrets Sync. Lee los destinos y, para cada secreto
# asociado, anota dónde vive: cuenta y región de AWS, Key Vault de Azure,
# proyecto y regiones de GCP Secret Manager, repositorio de GitHub o proyecto
# de Vercel. Si el endpoint no existe o la feature no está activa,
# secret_sync queda en "unknown".

set -euo pipefail

usage() {
  cat <<'EOF'
Uso:
  SECRET_MAX_AGE_DAYS=<dias> vault_secret_inventory.sh [--output fichero.csv]
  vault_secret_inventory.sh --max-age-days <dias> [--output fichero.csv]

Usa el CLI de Vault ya configurado (dirección, token y CA) para recorrer los
namespaces visibles, listar los mounts KV v2 y escribir un CSV con:

  namespace, secret_mount, mount_local, secret_path, absolute_path,
  created_time, updated_time, age_seconds, age_days, max_age_days,
  older_than_threshold, missing_metadata,
  owner, app, project, platform, env, team, custom_metadata,
  secret_sync, sync_destinations, sync_where, sync_targets, sync_api

older_than_threshold es true cuando el secreto es más viejo que
SECRET_MAX_AGE_DAYS. La edad sale de la marca más reciente entre la creación
del secreto y la versión actual.

missing_metadata es true cuando custom_metadata es null o está vacío.

mount_local es el campo local del mount en sys/mounts. true significa que el
KV es local al cluster: performance replication no replica sus datos. false
es un mount replicable.

secret_sync es true si el secreto tiene alguna asociación. sync_where dice
el sitio externo de cada una. sync_targets es el mismo dato en JSON.
Si Secrets Sync no responde, secret_sync queda en unknown.

En AWS, account sale del role_arn del destino (las access keys se devuelven
enmascaradas y no traen la cuenta). region es el campo region del destino.
En Azure, key_vault y key_vault_uri identifican el vault; region solo aparece
si el destino la guarda. En GCP, project es project_id y locations son las
replication_locations.
EOF
}

MAX_AGE_DAYS=""
OUTPUT=""
TMP_DIR=""
NS_FILE=""
SYNC_INDEX=""
SYNC_API_FILE=""
CSV_TMP=""
VAULT_API_HTTP=""
VAULT_API_BODY=""
TOTAL=0
MISSING=0
STALE=0
SYNCED=0
SYNC_UNKNOWN=0

parse_args() {
  MAX_AGE_DAYS="${SECRET_MAX_AGE_DAYS:-}"
  OUTPUT=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-age-days)
        [[ $# -ge 2 ]] || { echo "Falta el valor de --max-age-days" >&2; exit 2; }
        MAX_AGE_DAYS=$2
        shift 2
        ;;
      --output)
        [[ $# -ge 2 ]] || { echo "Falta el valor de --output" >&2; exit 2; }
        OUTPUT=$2
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Argumento no reconocido: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  if [[ -z "$MAX_AGE_DAYS" ]]; then
    echo "Indica la edad en días con SECRET_MAX_AGE_DAYS o --max-age-days." >&2
    usage >&2
    exit 2
  fi
  if ! [[ "$MAX_AGE_DAYS" =~ ^[0-9]+$ ]]; then
    echo "La edad tiene que ser un entero >= 0. Recibido: ${MAX_AGE_DAYS}" >&2
    exit 2
  fi
  if [[ -z "$OUTPUT" ]]; then
    OUTPUT="${INVENTORY_CSV:-secret-inventory.csv}"
  fi

  local bin
  for bin in vault jq awk; do
    command -v "$bin" >/dev/null 2>&1 || { echo "Falta el comando ${bin}" >&2; exit 1; }
  done
}

prepare_workspace() {
  TMP_DIR=$(mktemp -d)
  NS_FILE="${TMP_DIR}/namespaces"
  SYNC_INDEX="${TMP_DIR}/sync.jsonl"
  SYNC_API_FILE="${TMP_DIR}/sync-api.tsv"
  CSV_TMP="${TMP_DIR}/inventory.csv"
  trap 'rm -rf "$TMP_DIR"' EXIT
  touch "$SYNC_INDEX" "$SYNC_API_FILE"
  TOTAL=0
  MISSING=0
  STALE=0
  SYNCED=0
  SYNC_UNKNOWN=0
}

display_ns() {
  if [[ -z "${1:-}" ]]; then
    printf '/'
  else
    printf '/%s' "$1"
  fi
}

join_path() {
  local result="" part
  for part in "$@"; do
    [[ -n "$part" ]] || continue
    if [[ -z "$result" ]]; then
      result=$part
    else
      result="${result}/${part}"
    fi
  done
  printf '%s' "$result"
}

vault_api() {
  local method=$1
  local raw_path=$2
  local ns=${3-}
  local stdout_file stderr_file rc stdout stderr code
  stdout_file=$(mktemp)
  stderr_file=$(mktemp)
  rc=0
  if [[ "$method" == "LIST" ]]; then
    if [[ -n "$ns" ]]; then
      VAULT_NAMESPACE="$ns" vault list -format=json "$raw_path" >"$stdout_file" 2>"$stderr_file" || rc=$?
    else
      VAULT_NAMESPACE= vault list -format=json "$raw_path" >"$stdout_file" 2>"$stderr_file" || rc=$?
    fi
  else
    if [[ -n "$ns" ]]; then
      VAULT_NAMESPACE="$ns" vault read -format=json "$raw_path" >"$stdout_file" 2>"$stderr_file" || rc=$?
    else
      VAULT_NAMESPACE= vault read -format=json "$raw_path" >"$stdout_file" 2>"$stderr_file" || rc=$?
    fi
  fi
  stdout=$(cat "$stdout_file")
  stderr=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"

  if [[ $rc -eq 0 ]]; then
    VAULT_API_HTTP=200
    if [[ "$method" == "LIST" ]]; then
      VAULT_API_BODY=$(printf '%s' "$stdout" | jq -c '
        if type == "array" then {data:{keys:.}}
        elif (.data.keys? != null) then {data:{keys:.data.keys, key_info:(.data.key_info // {})}}
        elif (.keys? != null) then {data:{keys:.keys, key_info:(.key_info // {})}}
        else {data:{keys:[]}}
        end
      ')
    else
      VAULT_API_BODY=$(printf '%s' "$stdout" | jq -c 'if .data then . else {data:.} end')
    fi
    return 0
  fi

  if [[ $rc -eq 2 && ( -z "${stderr// /}" || "$stderr" == *"No value found"* ) ]]; then
    VAULT_API_HTTP=404
    VAULT_API_BODY='{"errors":[]}'
    return 1
  fi

  code=$(printf '%s\n' "$stderr" | sed -n 's/.*Code: \([0-9][0-9][0-9]\).*/\1/p')
  code=${code%%$'\n'*}
  if [[ -n "$code" ]]; then
    VAULT_API_HTTP=$code
  else
    VAULT_API_HTTP=000
  fi
  VAULT_API_BODY=$(jq -n --arg err "$stderr" '{errors:[$err]}')
  return 1
}

destination_where() {
  local type=$1
  local name=$2
  local body=$3
  printf '%s' "$body" | jq -c --arg type "$type" --arg name "$name" '
    def aws_account:
      (.role_arn // .account_id // "") as $raw
      | if ($raw | test("^[0-9]{12}$")) then $raw
        elif ($raw | test("arn:aws[a-z0-9-]*:iam::[0-9]{12}:")) then
          ($raw | capture("arn:aws[a-z0-9-]*:iam::(?<id>[0-9]{12}):").id)
        else ""
        end;
    def azure_name:
      (.key_vault_uri // "") as $u
      | if ($u | test("^https://[^./]+\\.vault\\.")) then
          ($u | capture("^https://(?<n>[^./]+)\\.vault\\.").n)
        else ""
        end;
    def as_csv:
      if type == "array" then join(",")
      elif . == null then ""
      else tostring
      end;
    (.data // {}) as $d
    | ($d.connection_details // {}) as $c
    | ($d.type // $type) as $t
    | ($c.replication_locations | as_csv) as $gcp_locations
    | {
        provider: (
          if $t == "aws-sm" then "aws-secrets-manager"
          elif $t == "azure-kv" then "azure-key-vault"
          elif $t == "gcp-sm" then "gcp-secret-manager"
          elif $t == "gh" then "github"
          elif $t == "vercel-project" then "vercel"
          else $t
          end
        ),
        destination_type: $t,
        destination_name: ($d.name // $name),
        account: (if $t == "aws-sm" then ($c | aws_account) else "" end),
        region: (
          if $t == "aws-sm" then ($c.region // "")
          elif $t == "azure-kv" then ($c.region // $c.location // "")
          elif $t == "gcp-sm" then $gcp_locations
          else ($c.region // "")
          end
        ),
        role_arn: (if $t == "aws-sm" then ($c.role_arn // "") else "" end),
        key_vault: (if $t == "azure-kv" then ($c | azure_name) else "" end),
        key_vault_uri: (if $t == "azure-kv" then ($c.key_vault_uri // "") else "" end),
        tenant_id: (if $t == "azure-kv" then ($c.tenant_id // "") else "" end),
        cloud: (if $t == "azure-kv" then ($c.cloud // "") else "" end),
        project: (if $t == "gcp-sm" then ($c.project_id // "") else "" end),
        locations: (if $t == "gcp-sm" then $gcp_locations else "" end),
        repository: (if $t == "gh" then ($c.repository_name // "") else "" end),
        organization: (if $t == "gh" then ($c.organization_name // $c.repository_owner // "") else "" end),
        environment: (if $t == "gh" then ($c.environment_name // "") else "" end),
        enterprise_url: (if $t == "gh" then ($c.enterprise_url // "") else "" end),
        project_id: (if $t == "vercel-project" then ($c.project_id // "") else "" end),
        team_id: (if $t == "vercel-project" then ($c.team_id // "") else "" end),
        environments: (if $t == "vercel-project" then ($c.deployment_environments | as_csv) else "" end)
      }
  '
}

classify_sync() {
  local http=$1
  local body=$2
  local err
  if [[ "$http" =~ ^2 ]]; then
    printf 'available'
    return 0
  fi
  err=$(printf '%s' "$body" | jq -r '(.errors // []) | join(" ")' 2>/dev/null || true)
  if [[ "$http" == "404" && -z "${err// /}" ]]; then
    printf 'available'
    return 0
  fi
  printf 'unavailable'
}

collect_namespaces() {
  local parent=$1
  local http body keys child full
  printf '%s\n' "$parent" >> "$NS_FILE"
  vault_api LIST "sys/namespaces" "$parent" || true
  http=$VAULT_API_HTTP
  body=$VAULT_API_BODY
  if [[ "$http" == "404" ]]; then
    return 0
  fi
  if [[ ! "$http" =~ ^2 ]]; then
    echo "No se pudieron listar los namespaces en $(display_ns "$parent") (HTTP ${http})." >&2
    printf '%s\n' "$body" >&2
    exit 1
  fi
  keys=$(printf '%s' "$body" | jq -r '.data.keys[]? // empty')
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    child=${child%/}
    if [[ -z "$parent" ]]; then
      full=$child
    else
      full="${parent}/${child}"
    fi
    collect_namespaces "$full"
  done <<< "$keys"
}

record_sync() {
  local ns=$1
  local http body avail type name names_http names_body assoc_http assoc_body api
  local where dest_http dest_body
  vault_api LIST "sys/sync/destinations" "$ns" || true
  http=$VAULT_API_HTTP
  body=$VAULT_API_BODY
  avail=$(classify_sync "$http" "$body")
  printf '%s\t%s\n' "$ns" "$avail" >> "$SYNC_API_FILE"
  if [[ "$avail" != "available" ]]; then
    if [[ ! -f "${TMP_DIR}/sync_warned" ]]; then
      echo "[aviso] Secrets Sync no se pudo consultar en $(display_ns "$ns") (HTTP ${http}). Esos secretos quedan como secret_sync=unknown." >&2
      printf '%s\n' "$body" >&2
      touch "${TMP_DIR}/sync_warned"
    fi
    return 0
  fi
  if [[ ! "$http" =~ ^2 ]]; then
    return 0
  fi
  while IFS= read -r type; do
    [[ -n "$type" ]] || continue
    type=${type%/}
    api="sys/sync/destinations/$(join_path "$type")"
    vault_api LIST "$api" "$ns" || true
    names_http=$VAULT_API_HTTP
    names_body=$VAULT_API_BODY
    if [[ ! "$names_http" =~ ^2 ]]; then
      continue
    fi
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      name=${name%/}
      where='{}'
      api="sys/sync/destinations/$(join_path "$type" "$name")"
      vault_api GET "$api" "$ns" || true
      dest_http=$VAULT_API_HTTP
      dest_body=$VAULT_API_BODY
      if [[ "$dest_http" =~ ^2 ]]; then
        where=$(destination_where "$type" "$name" "$dest_body")
      else
        echo "[aviso] destino ${type}/${name} en $(display_ns "$ns") HTTP ${dest_http}" >&2
      fi
      api="sys/sync/destinations/$(join_path "$type" "$name")/associations"
      vault_api GET "$api" "$ns" || true
      assoc_http=$VAULT_API_HTTP
      assoc_body=$VAULT_API_BODY
      if [[ ! "$assoc_http" =~ ^2 ]]; then
        echo "[aviso] asociaciones ${type}/${name} en $(display_ns "$ns") HTTP ${assoc_http}" >&2
        continue
      fi
      printf '%s' "$assoc_body" | jq -c \
        --arg ns "$ns" \
        --arg dest "${type}/${name}" \
        --argjson where "$where" \
        '
          (.data.associated_secrets // {})
          | to_entries[]
          | {
              namespace: $ns,
              accessor: (.value.accessor // ""),
              secret_name: (.value.secret_name // ""),
              destination: $dest,
              sync_status: (.value.sync_status // "UNKNOWN"),
              where: $where
            }
        ' >> "$SYNC_INDEX"
    done < <(printf '%s' "$names_body" | jq -r '.data.keys[]? // empty')
  done < <(printf '%s' "$body" | jq -r '.data.keys[]? // empty')
}

sync_api_for() {
  local ns=$1
  local value
  value=$(awk -F '\t' -v ns="$ns" '$1 == ns { print $2; exit }' "$SYNC_API_FILE")
  if [[ -z "$value" ]]; then
    printf 'unavailable'
  else
    printf '%s' "$value"
  fi
}

format_secret_row() {
  local meta_json=$1
  local matches_json=$2
  local ns_col=$3
  local mount=$4
  local mount_local=$5
  local secret_path=$6
  local absolute=$7
  local sync_api=$8
  local max_age=$9
  jq -nr \
    --argjson meta "$meta_json" \
    --argjson matches "$matches_json" \
    --arg namespace "$ns_col" \
    --arg mount "$mount" \
    --arg mount_local "$mount_local" \
    --arg secret_path "$secret_path" \
    --arg absolute "$absolute" \
    --arg sync_api "$sync_api" \
    --arg max_age "$max_age" \
    '
      def ts_epoch:
        if type != "string" or . == "" then null
        else sub("\\.[0-9]+"; "") | fromdateiso8601
        end;
      def place($k; $v):
        if ($v | tostring) == "" or $v == null then empty else "\($k)=\($v)" end;
      def target:
        . as $m
        | ($m.where // {}) as $w
        | [
            ($w.provider // $m.destination),
            ($m.destination // ""),
            ("status=" + ($m.sync_status // "")),
            place("account"; $w.account),
            place("region"; $w.region),
            place("role_arn"; $w.role_arn),
            place("key_vault"; $w.key_vault),
            place("key_vault_uri"; $w.key_vault_uri),
            place("tenant"; $w.tenant_id),
            place("cloud"; $w.cloud),
            place("project"; $w.project),
            (if ($w.locations // "") != "" and ($w.locations // "") != ($w.region // "") then place("locations"; $w.locations) else empty end),
            place("organization"; $w.organization),
            place("repository"; $w.repository),
            place("environment"; $w.environment),
            place("enterprise_url"; $w.enterprise_url),
            place("project_id"; $w.project_id),
            place("team_id"; $w.team_id),
            place("environments"; $w.environments)
          ] | join(" ");

      $meta.data as $d
      | ($d.created_time // "") as $created_raw
      | (
          ($d.current_version // 0) as $cv
          | if $cv == 0 then ""
            else ($d.versions[$cv | tostring].created_time // "")
            end
        ) as $updated_raw
      | ($created_raw | ts_epoch) as $created_epoch
      | ($updated_raw | ts_epoch) as $updated_epoch
      | [$created_epoch, $updated_epoch] | map(select(. != null)) as $stamps
      | (if ($stamps | length) == 0 then null else ($stamps | max) end) as $last
      | (now | floor) as $now
      | (if $last == null then "" else (($now - $last) | floor | tostring) end) as $age_seconds
      | (if $last == null then "" else ((($now - $last) / 86400) | floor | tostring) end) as $age_days
      | (
          if $last == null then "unknown"
          elif ($now - $last) > (($max_age | tonumber) * 86400) then "true"
          else "false"
          end
        ) as $stale
      | ($d.custom_metadata // {}) as $cm
      | (if ($cm | type) != "object" or ($cm | length) == 0 then "true" else "false" end) as $missing
      | (
          if $sync_api != "available" then "unknown"
          elif ($matches | length) > 0 then "true"
          else "false"
          end
        ) as $synced
      | ([$matches[]? | "\(.destination):\(.sync_status)"] | join("|")) as $dests
      | ([$matches[]? | target] | join("|")) as $where_text
      | ([$matches[]? | {
            destination,
            sync_status,
            provider: (.where.provider // ""),
            account: (.where.account // ""),
            region: (.where.region // ""),
            role_arn: (.where.role_arn // ""),
            key_vault: (.where.key_vault // ""),
            key_vault_uri: (.where.key_vault_uri // ""),
            tenant_id: (.where.tenant_id // ""),
            cloud: (.where.cloud // ""),
            project: (.where.project // ""),
            locations: (.where.locations // ""),
            organization: (.where.organization // ""),
            repository: (.where.repository // ""),
            environment: (.where.environment // ""),
            enterprise_url: (.where.enterprise_url // ""),
            project_id: (.where.project_id // ""),
            team_id: (.where.team_id // ""),
            environments: (.where.environments // "")
          }] | tojson) as $targets
      | {
          csv: ([
            $namespace,
            $mount,
            $mount_local,
            $secret_path,
            $absolute,
            $created_raw,
            (if $updated_raw == "" then $created_raw else $updated_raw end),
            $age_seconds,
            $age_days,
            $max_age,
            $stale,
            $missing,
            ($cm.owner // ""),
            ($cm.app // ""),
            ($cm.project // ""),
            ($cm.platform // ""),
            ($cm.env // ""),
            ($cm.team // ""),
            ($cm | tojson),
            $synced,
            $dests,
            $where_text,
            $targets,
            $sync_api
          ] | @csv),
          stale: $stale,
          missing: $missing,
          synced: $synced
        }
    '
}

emit_secret() {
  local ns=$1
  local mount=$2
  local secret_path=$3
  local accessor=$4
  local mount_local=$5
  local -a segments parts
  local part api http body ns_col absolute matches sync_api parsed
  segments=("$mount" "metadata")
  IFS='/' read -ra parts <<< "$secret_path"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] && segments+=("$part")
  done
  api=$(join_path "${segments[@]}")
  vault_api GET "$api" "$ns" || true
  http=$VAULT_API_HTTP
  body=$VAULT_API_BODY
  ns_col=$(display_ns "$ns")
  if [[ "$ns_col" == "/" ]]; then
    absolute="/${mount}/${secret_path}"
  else
    absolute="${ns_col}/${mount}/${secret_path}"
  fi
  if [[ ! "$http" =~ ^2 ]]; then
    echo "[aviso] sin metadata para ${absolute} (HTTP ${http})" >&2
    return 0
  fi
  if ! printf '%s' "$body" | jq -e '.data' >/dev/null 2>&1; then
    echo "[aviso] respuesta de metadata no válida para ${absolute}" >&2
    return 0
  fi
  matches=$(jq -c -s \
    --arg ns "$ns" \
    --arg acc "$accessor" \
    --arg name "$secret_path" \
    'map(select(.namespace == $ns and .secret_name == $name and (.accessor == $acc or $acc == "" or .accessor == "")))' \
    "$SYNC_INDEX")
  sync_api=$(sync_api_for "$ns")
  parsed=$(format_secret_row "$body" "$matches" "$ns_col" "$mount" "$mount_local" "$secret_path" "$absolute" "$sync_api" "$MAX_AGE_DAYS")
  printf '%s\n' "$(printf '%s' "$parsed" | jq -r '.csv')" >> "$CSV_TMP"
  TOTAL=$((TOTAL + 1))
  case "$(printf '%s' "$parsed" | jq -r '.missing')" in
    true) MISSING=$((MISSING + 1)) ;;
  esac
  case "$(printf '%s' "$parsed" | jq -r '.stale')" in
    true) STALE=$((STALE + 1)) ;;
  esac
  case "$(printf '%s' "$parsed" | jq -r '.synced')" in
    true) SYNCED=$((SYNCED + 1)) ;;
    unknown) SYNC_UNKNOWN=$((SYNC_UNKNOWN + 1)) ;;
  esac
}

walk_kv() {
  local ns=$1
  local mount=$2
  local prefix=$3
  local accessor=$4
  local mount_local=$5
  local -a segments parts
  local part api http body key
  segments=("$mount" "metadata")
  if [[ -n "$prefix" ]]; then
    IFS='/' read -ra parts <<< "${prefix%/}"
    for part in "${parts[@]}"; do
      [[ -n "$part" ]] && segments+=("$part")
    done
  fi
  api=$(join_path "${segments[@]}")
  vault_api LIST "$api" "$ns" || true
  http=$VAULT_API_HTTP
  body=$VAULT_API_BODY
  if [[ "$http" == "404" ]]; then
    return 0
  fi
  if [[ ! "$http" =~ ^2 ]]; then
    echo "[aviso] no se pudo listar $(display_ns "$ns")/${mount}/${prefix} (HTTP ${http})" >&2
    return 0
  fi
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if [[ "$key" == */ ]]; then
      walk_kv "$ns" "$mount" "${prefix}${key}" "$accessor" "$mount_local"
    else
      emit_secret "$ns" "$mount" "${prefix}${key}" "$accessor" "$mount_local"
    fi
  done < <(printf '%s' "$body" | jq -r '.data.keys[]? // empty')
}

scan_namespace() {
  local ns=$1
  local http body mount accessor mount_local
  echo "[scan] $(display_ns "$ns")"
  record_sync "$ns"
  vault_api GET "sys/mounts" "$ns" || true
  http=$VAULT_API_HTTP
  body=$VAULT_API_BODY
  if [[ ! "$http" =~ ^2 ]]; then
    echo "[aviso] no se pudieron listar los mounts de $(display_ns "$ns") (HTTP ${http})" >&2
    return 0
  fi
  while IFS=$'\t' read -r mount accessor mount_local; do
    [[ -n "$mount" ]] || continue
    mount=${mount%/}
    walk_kv "$ns" "$mount" "" "$accessor" "$mount_local"
  done < <(printf '%s' "$body" | jq -r '
    .data
    | to_entries[]
    | select(.value.type == "kv")
    | select((((.value.options // {}).version) // "1" | tostring) == "2")
    | "\(.key)\t\(.value.accessor // "")\t\((.value.local // false) | tostring)"
  ')
}

main() {
  local ns out_dir
  parse_args "$@"
  prepare_workspace
  : > "$NS_FILE"
  collect_namespaces ""
  printf '%s\n' \
    "namespace,secret_mount,mount_local,secret_path,absolute_path,created_time,updated_time,age_seconds,age_days,max_age_days,older_than_threshold,missing_metadata,owner,app,project,platform,env,team,custom_metadata,secret_sync,sync_destinations,sync_where,sync_targets,sync_api" \
    > "$CSV_TMP"
  while IFS= read -r ns; do
    scan_namespace "$ns"
  done < "$NS_FILE"
  out_dir=$(dirname "$OUTPUT")
  mkdir -p "$out_dir"
  mv "$CSV_TMP" "$OUTPUT"
  # El trap borra TMP_DIR. El CSV ya está fuera.
  echo
  echo "secretos=${TOTAL}"
  echo "missing_metadata=${MISSING}"
  echo "secret_sync=${SYNCED}"
  echo "secret_sync_unknown=${SYNC_UNKNOWN}"
  echo "older_than_threshold=${STALE}"
  echo "max_age_days=${MAX_AGE_DAYS}"
  echo "csv=${OUTPUT}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
