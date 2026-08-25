# ryan.xtweet

Compose X (Twitter) posts from the Omarchy bar.

## Posting modes

**Browser composer (default, free)** — opens the X Web Intent URL via `xdg-open`.  You press the final Post button in your browser.  No API keys needed.

**Paid API** — posts directly to the X API (`POST /2/tweets`) with OAuth 1.0a signing.  Explicitly opt-in; the backend refuses this mode unless `paid_api = true` **and** all four credential fields are non-empty.

Pricing is pay-per-use and changes over time.  The **X Developer Console** ([developer.x.com](https://developer.x.com)) is authoritative.  As of writing, publishing costs roughly:

| Content        | Approx. cost per post |
|----------------|----------------------|
| Text-only      | $0.015               |
| Contains a URL | $0.20                |

## Install

```sh
omarchy plugin add https://github.com/rmacy/ryan.xtweet.git --enable
```

## Configure

```sh
mkdir -m 700 -p ~/.config/xtweet
cp ~/.config/omarchy/plugins/ryan.xtweet/config.example.toml ~/.config/xtweet/config.toml
chmod 600 ~/.config/xtweet/config.toml
```

Edit `~/.config/xtweet/config.toml` to set `paid_api` and, if using the paid API, the four OAuth 1.0a fields.  The backend also generates this template with correct permissions on first run.

## Controls

- Click the X icon in the bar to open the composer panel.
- **Enter** submits; **Shift+Enter** inserts a newline; **Escape** dismisses.
- The action button label reflects the active mode: *Continue in X* (browser) or *Post* (paid API).
- The bar button tooltip also adapts: *Compose on X* vs *New post*.

Drafts persist across panel open/close cycles and are shared across monitors.

## Optional CLI

The `bin/xtweet` wrapper resolves the backend relative to itself.  Symlink it into your PATH:

```sh
ln -sf ~/.config/omarchy/plugins/ryan.xtweet/bin/xtweet ~/.local/bin/xtweet
```

Post text is always passed on **stdin**, never as a command-line argument:

```sh
printf '%s' 'Your post text here' | xtweet post
```

Other commands (`mode`, `enqueue`, `status`, `active`, `ack`, `draft`) pass through directly to the backend.

Exit codes: **0** posted or composer opened; **1** failed / busy / unknown; **2** usage error.

## File architecture

```
backend.py              Posting backend (Python 3.11+ stdlib only)
Service.qml             Singleton service: backend IPC, draft state, job queue
Panel.qml               Per-monitor composer UI
manifest.json           Omarchy plugin metadata
config.example.toml     Configuration template
xtweet.png              Bar icon
bin/xtweet              Optional CLI wrapper (resolves backend relative to itself)
tests/test_backend.py   Isolated stdlib backend regression suite
pyproject.toml          Poetry development metadata (runtime has no dependencies)
LICENSE                 MIT license
```

Runtime state (job files, locks) lives under `$XDG_RUNTIME_DIR/ryan.xtweet`.  Credentials are read from `~/.config/xtweet/config.toml` (0700 dir, 0600 file) and never copied into job files.

## Development

```sh
omarchy plugin validate .
poetry run python tests/test_backend.py
```

Runtime never depends on Poetry.

## Security

- `~/.config/xtweet` is created with mode 0700; `config.toml` with 0600.  Symlinks, foreign owners, and group/other permission bits are refused.
- OAuth secrets are never logged, echoed, or included in JSON output.
- The Web Intent URL embeds draft text and is never returned in JSON or logs.
- Post text arrives via stdin or job files — never via shell interpolation or command-line arguments.

## Uninstall

```
omarchy plugin remove ryan.xtweet
```

Remove the optional CLI symlink and configuration if desired:

```sh
rm -f ~/.local/bin/xtweet
rm -rf ~/.config/xtweet
```

## License

MIT — see [LICENSE](LICENSE).
