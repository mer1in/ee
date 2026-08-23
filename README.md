# ee

Keep credentials in an **encrypted store** and load them into your shell
as environment variables — per cloud type, with prompt badges so you always
know which contexts are active. Running `ee` with no arguments opens the
interactive tui; you can also drive it from the CLI.

## Installation

The script must be *sourced* so exported variables reach your shell, via an
alias in `~/.bashrc`:

```bash
alias ee='. /path/to/ee.sh'
```

`ee install` (run with `bash ee.sh install`, before the alias exists) adds
this line to `~/.bashrc` for you, pointing at wherever `ee.sh` currently
lives. It refuses to touch `~/.bashrc` if an `ee` alias is already defined
there — remove or rename the existing one first. Run `source ~/.bashrc` (or
restart your shell) afterwards.

Requirements: `bash`, `openssl`, `jq`.

## Commands

| Command | Description |
| --- | --- |
| `ee` | Interactive browser/editor for the store (the default). |
| `ee tui` | Same as `ee` — the tui, explicitly. |
| `ee <key-name>` | Shortcut for `ee inject <key-name>`. |
| `ee inject <key-name>` | Decrypt the store and export the record's variables. |
| `ee ls` | List saved records with their type. |
| `ee add <key-name> [--type=…] …` | Create or update a (typed) record. |
| `ee save <filename.json> [--force]` | Encrypt a plaintext JSON file into the store. |
| `ee install` | Add the `ee` alias to `~/.bashrc`, pointing at this script. |
| `ee off` | Unset every variable the tool exported (see below). |
| `ee danger on` \| `off` | Cache the master password in the environment. |
| `ee test` | Run the built-in temp-store self-test. |
| `ee help` | Print usage (`--help` and `-h` work too). |

### Default mode: the tui

`ee` with no command (and `ee --storage <path>` with no command) opens the
interactive tui. `ee tui` is the same thing, spelled out.

Any other token that isn't one of the subcommands above is treated as a key
name to inject — `ee myenv` behaves exactly like `ee inject myenv`, including
`--storage` support and the same error handling. If a saved key happens to
share a name with a real subcommand (`ls`, `save`, ...), the subcommand
wins; reach that key with `ee inject <name>` or through the tui instead.

### The `--storage` option

`--storage <path>` (or `--storage=<path>`) selects an alternate encrypted
store for `inject`, `ls`, `add`, `save`, and `tui`. It may be placed
**anywhere** on the command line:

```bash
ee --storage ~/work/store.enc ls
ee ls --storage ~/work/store.enc
ee add proj-aws --AWS_ACCESS_KEY_ID=… --storage ~/work/store.enc --AWS_SECRET_ACCESS_KEY=…
```

The default store is `~/.cloud-env/credentials.json.enc` (override with the
`CLOUD_ENV_STORE_PATH` environment variable).

## Adding records

Every option accepts both `--opt value` and `--opt=value`. Fields are set
with their **explicit environment variable name** — there are no per-type
shortcut flags.

**AWS** (requires access key + secret; region falls back to
`CLOUD_ENV_DEFAULT_REGION`, default `eu-central-1`):

```bash
ee add proj-aws --type=AWS \
    --AWS_ACCESS_KEY_ID=<id> --AWS_SECRET_ACCESS_KEY=<secret> [--AWS_DEFAULT_REGION=<region>]
```

**GCP** (requires both fields):

```bash
ee add proj-gcp --type=GCP \
    --CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE=/path/key.json --CLOUDSDK_CORE_PROJECT=<project-id>
```

**Azure** (requires all four fields):

```bash
ee add proj-az --type=Azure \
    --AZURE_CLIENT_ID=<id> --AZURE_CLIENT_SECRET=<secret> \
    --AZURE_TENANT_ID=<id> --AZURE_SUBSCRIPTION_ID=<id>
```

**Custom types** — any type name that isn't AWS/GCP/Azure is stored as-is,
with fields set the same way, via explicit `--VAR_NAME=value` flags (or the
equivalent `--set NAME=VALUE`):

```bash
ee add proj-custom --type=qqq --API_TOKEN=<token> --API_URL=<url>
# equivalent:
ee add proj-custom --type=qqq --set API_TOKEN=<token> --set API_URL=<url>
```

`--set NAME=VALUE` is always available as an alternate spelling of
`--NAME=VALUE`, for known and custom types alike.

Where to create long-lived credentials:

- AWS — [IAM access keys](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html#Using_CreateAccessKey)
- GCP — [Service account keys](https://cloud.google.com/iam/docs/keys-create-delete)
- Azure — [App registration client secret/certificate](https://learn.microsoft.com/en-us/entra/identity-platform/howto-create-service-principal-portal)

## tui

The tui is the default mode (`ee`, or `ee tui`). It is an interactive,
keyboard-driven browser/editor for the store — no need to remember flags.
If danger mode is already on, tui reuses the cached master password and
does not prompt. Otherwise, if the store doesn't exist yet, it warns you
and asks for a new master password; if the store exists, it asks for the
existing one, once, up front. Every write (add, update, delete) persists
immediately, so there's nothing separate to "save".

Navigation: `j`/`k` (or `↑`/`↓`) to move, `Enter`/`l` to open, `h`/`Esc`/`q`
to go back or quit. Every screen shows a one-line reminder of the keys that
work there.

**LIST** (the default screen) shows every record and its type:

- `i` — inject the highlighted record and exit tui (same effect as
  `ee inject <name>`)
- `a` — add a new record: prompts for a name, then a type (pick one already
  used in the store, AWS/GCP/Azure, or type your own), then its required
  fields if the type is known, then any extra custom fields
- `d` — delete the highlighted record, after a `Delete <name>? y/N` confirm
- `Enter`/`l` — open the record's field view

**Field view** shows one record's fields, values masked as `***`:

- `v` — reveal/hide the highlighted field's value
- `u` — update the highlighted field's value
- `a` — add a new field to this record (refuses to overwrite an existing
  one — use `u` for that)

A password typed during a `tui` session is held only for that session —
it's forgotten the moment you quit (`q`/`Esc` from LIST, or after
injecting). tui never turns danger mode on or off; if danger mode was
already active, its cached password and badge stay as they were.

## Behavior notes

- **Active contexts are tracked per cloud type**, so AWS, GCP, Azure — and any
  custom types — can be active together, each with its own prompt badge.
- **Injecting a key replaces only that key's type.** For example, injecting an
  AWS key replaces the previous AWS context (including variables the new
  record doesn't define) while keeping GCP, Azure, and custom contexts
  untouched.
- **Record type validation:** known types (AWS, GCP, Azure — matched
  case-insensitively) demand their defined set of fields, supplied via
  `--VAR_NAME=value` or `--set NAME=VALUE`. For unknown types like `qqq`, no
  specific fields are demanded.
- **`ee off`** unsets every variable the tool exported — it tracks what it
  exported at inject time, so this works for known and custom types alike
  without decrypting the store. It also drops the cached master password if
  danger mode was enabled.
- Records without a `type` field are treated as AWS for backwards
  compatibility.
- Failures never destroy your current context: a typo'd key name or a failed
  decryption leaves the active environment untouched.

## Danger mode

`ee danger on` reads the master password via a **hidden stdin prompt** and
keeps it in the environment (`CLOUD_ENV_MASTER_PASSWORD`), so subsequent
commands don't prompt. The password is deliberately *not* accepted as a
command-line argument — that would leak it into shell history and the process
list. While enabled, a red `DANGER` badge is shown in the prompt.

`ee danger off` forgets the password and removes the badge.

## PS1 integration

Add `CLOUD_PS1_KEY` to your prompt so active cloud contexts are visible.
Example for Bash:

```bash
export PS1='${CLOUD_PS1_KEY}${CLOUD_PS1_KEY:+ }'"$PS1"
```

What you will see:

- one badge per active cloud type (AWS, GCP, Azure, custom types, …)
- when injecting another key of the same type, only that type's badge is replaced
- a separate `DANGER` badge while danger mode is enabled

## Testing

```bash
./test.sh      # full integration suite (isolated temp stores, non-interactive)
ee test        # built-in quick self-test against a throwaway temp store
```

Both are non-destructive: they use throwaway directories, never the real
`~/.cloud-env` store or `~/.bashrc`. `ee test` runs in a subshell, so it
does not unset or overwrite credentials already exported in your shell.

## Future plans

Optional remote backends, so records can be sourced from a secrets manager
instead of (or in addition to) the local encrypted file:

- **HashiCorp Vault** — authenticate (token, AppRole, or similar), then map
  Vault KV paths onto `ee` records so `inject` / the tui can pull live
  values without copying them into the local openssl store.
- **Keeper Security** — the same idea against Keeper Secrets Manager (or
  Commander): browse Keeper records in the tui and inject them as
  environment variables.

The local encrypted store remains the default; these would be opt-in
backends selected per record or via `--storage`-style configuration.
