# Marlow Depot — parts adviser

A small service the depot uses to turn a maintenance complaint into a part number.

```
depot-api/
  app.py            FastAPI service: GET /health, GET /whoami, POST /match
  indexer.py        one-shot index build; writes into DEPOT_INDEX_DIR and exits
  matching.py       the token scoring both of the above share
  catalog/parts.json  the depot catalogue
  vendor/depot_hash/  the fingerprint routine, built from C at install time
  requirements.txt  pinned dependencies
  version.txt       the version string /health reports
  .env              DEPOT_API_KEY — never let this reach an image
```

## How the two processes fit together

`indexer.py` reads the catalogue, writes `parts_index.csv`, `tokens_index.csv`
and finally `manifest.json` into `DEPOT_INDEX_DIR`, then exits 0.

`app.py` checks for `manifest.json` **before it imports anything else** and
exits with status 3 if it is not there. So the index build has to finish before
the API starts; there is no retry loop and no partially-served catalogue.

## Environment

- `DEPOT_INDEX_DIR` — where the index is read and written (default `/index`).
  Whatever user the process runs as has to be able to write it.
- `DEPOT_CATALOG` — catalogue path (default `catalog/parts.json`, relative to
  the working directory).
- `DEPOT_VERSION_FILE` — version file (default `version.txt`).
- `DEPOT_LLM_URL` — adviser backend base URL (default `http://llm:9000/v1`).
- `DEPOT_API_KEY` — credential sent to the adviser backend. Supplied at run
  time from `.env`.

## Endpoints

- `GET /health` → `{"status","version","indexed_parts","indexed_tokens","catalog_fp"}`
- `GET /whoami` → `{"version","uid","user","key_fp","hash_fp","llm_url"}`
- `POST /match` `{"need": "..."}` → the best part plus a one-line note from the
  adviser backend.

## Running it without containers

Not supported on this machine: the dependencies are installed by the image
build, not on the host. Bring the stack up with Compose instead.
