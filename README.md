Register in ~/.bashrc with:
```bash
alias cloud-env='. ~/.local/bin/cloud-env.sh'
```

Useful commands:
- `cloud-env set [--storage <path>] <key-name>` to load a record.
- `cloud-env ls [--storage <path>]` to list saved records with their type.
- `cloud-env add [--storage <path>] <key-name> --type=AWS|GCP|Azure ...` to save typed records.
- `cloud-env save [--storage <path>] <filename.json>` to write encrypted records to a specific store path.
- `cloud-env danger on` to keep the master password in the environment (password is read via hidden stdin prompt).
- `cloud-env test` to run the temp-store self-test.

Behavior notes:
- Active contexts are tracked per cloud type, so AWS and GCP can be active together.
- Setting a key replaces only that key's type (for example, setting AWS replaces AWS while keeping GCP and Azure untouched).
- Record type validation is strict (defaults: AWS, GCP, Azure). Unknown types like `qqq` are rejected.
- To extend allowed types intentionally, set `CLOUD_ENV_SUPPORTED_TYPES`, for example: `export CLOUD_ENV_SUPPORTED_TYPES="AWS GCP Azure Oracle K8S"`.
