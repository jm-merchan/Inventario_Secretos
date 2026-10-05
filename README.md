# Inventario de secretos

Notebook y script para inventariar secretos KV v2 de HashiCorp Vault Enterprise.

El lote de demostración son 100 secretos repartidos en 15 namespaces anidados. Cada namespace tiene más de un mount KV v2. 75 secretos llevan metadatos de atribución (`owner`, `app`, `project`, `platform`, `env`, `team`) y 25 se crean sin `custom_metadata`.

## Contenido

- `9_Inventario_Secretos.ipynb` carga el lote, ejecuta el inventario y explora el CSV.
- `scripts/vault_secret_inventory.sh` recorre namespaces, mounts y paths, y escribe el CSV.

## Requisitos

- CLI de Vault ya autenticado (`VAULT_ADDR`, `VAULT_TOKEN`, `VAULT_CACERT` o `VAULT_SKIP_VERIFY`, fichero de token o agent). El script no abre otro login.
- `jq` y `awk`.
- Para el notebook: Python con `pandas`, `Jinja2`, `plotly`, `ipywidgets` y `anywidget`.

Antes de ejecutar las celdas, exporta tu propio token. El notebook deja el sitio `VAULT_TOKEN=<tu-token>`.

## Uso del script

```bash
export VAULT_ADDR=https://vault.ejemplo.com
export VAULT_TOKEN=<tu-token>

SECRET_MAX_AGE_DAYS=90 ./scripts/vault_secret_inventory.sh --output inventario.csv
./scripts/vault_secret_inventory.sh --max-age-days 30 --output inventario.csv
```

El CSV incluye los KV v2 que el token puede leer. Estas son las columnas:

`namespace`, `secret_mount`, `mount_local`, `secret_path`, `absolute_path`, `created_time`, `updated_time`, `age_seconds`, `age_days`, `max_age_days`, `older_than_threshold`, `missing_metadata`, `owner`, `app`, `project`, `platform`, `env`, `team`, `custom_metadata`, `secret_sync`, `sync_destinations`, `sync_where`, `sync_targets`, `sync_api`.

`missing_metadata` marca secretos sin `custom_metadata`. `older_than_threshold` marca los que son más viejos que `SECRET_MAX_AGE_DAYS`. Para Secrets Sync, el script anota si el secreto está asociado y dónde: cuenta y región de AWS, Key Vault de Azure, proyecto y regiones de GCP, repositorio de GitHub o proyecto de Vercel. No crea destinos.
