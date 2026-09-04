# claude-timestamps

Claude Code transcripts record what was said but show you almost nothing about when.
This plugin adds the missing time axis. A `Stop` hook emits one short stamp per turn, so
the conversation carries a visible clock as it happens. A `MessageDisplay` hook and a
`UserPromptSubmit` hook write a small, millisecond-accurate log of turn starts and
assistant messages — message metadata only, never message text. And `/timestamps` reads
the session transcript on disk and prints a timestamped timeline, which works on sessions
recorded before you installed the plugin, since the transcript already holds the timing.

![Hovering a session in Claude Code's sidebar reveals an exact timestamp as a tooltip, over a relative time like "5 hours ago"](docs/example.png)

This is as precise as Claude Code gets today: hover a session in the sidebar for an exact
time, tucked behind a relative one. Nothing that specific exists inside a conversation, and
nothing exists per turn. This plugin puts a real clock there instead.

## Install

From inside Claude Code:

```
/plugin marketplace add dscx/claude-app-plugin-timestamps
/plugin install claude-timestamps@claude-timestamps
```

Or from a shell:

```
claude plugin marketplace add dscx/claude-app-plugin-timestamps
claude plugin install claude-timestamps@claude-timestamps
```

The repository is `claude-app-plugin-timestamps` but the plugin and its marketplace are
both named `claude-timestamps`, which is why the second command does not repeat the
repository name. To work on the plugin instead, point the marketplace at a local checkout:
`claude plugin marketplace add /path/to/claude-app-plugin-timestamps`.

Restart Claude Code afterwards. Hook definitions are read when a session starts, so an
already-running session will not pick up the plugin until it is restarted.

### Updating

The install cache is keyed by the `version` in `.claude-plugin/plugin.json`:
`claude plugin marketplace update claude-timestamps` reports success but leaves the
installed copy alone unless that version changed. If you are editing the plugin locally,
`claude plugin uninstall` followed by `claude plugin install` is the only reliable way to
pick your changes up.

## What you'll actually see

The visible per-turn stamp is a `systemMessage` from the `Stop` hook. Where it lands
depends on which client you are in:

- **Terminal (TUI):** it renders inline in the conversation, on its own line, as
  `Stop says: 14:32:07 (turn 41s)`.
- **Desktop app:** it is collapsed behind a **"Claude Code notice"** dropdown. You have to
  expand the notice to read the stamp. It is not shown inline.

This is a platform constraint, not a bug in this plugin. A `Stop` hook has exactly one
channel for putting text in front of you — `systemMessage` — and each client decides how
to present that channel. Plain stdout from a `Stop` hook renders nothing at all, and
`suppressOutput` does not affect `systemMessage` either way. There is no supported way for
a hook to write into the assistant's own message bubble.

If you are mainly in the desktop app and want a stamp you can read without expanding
anything, use `MODE=inline` (see below) and accept its trade-off, or lean on `/timestamps`,
which renders identically in both clients.

## Modes

Set `MODE` in the config file described under Configuration.

| Mode | What it does | Trade-off |
| --- | --- | --- |
| `notice` (default) | The `Stop` hook emits the stamp as a `systemMessage`. | Exact and deterministic — the time comes from the hook, not the model — but you do not get to choose where it renders. Inline in the terminal, collapsed behind the "Claude Code notice" dropdown in the desktop app. |
| `inline` | The plugin asks the model to type the stamp into the top of its own reply, so it appears in the message body in every client. | Model-typed, therefore best-effort: the model can forget it, reword it, or drop it on a long turn, and nothing detects that. The value it types is the **turn-start** time it was given at the beginning of the turn, so it is not the moment the reply finished. Use it for readability, not for measurement. |
| `off` | No visible stamp. | Nothing appears in the conversation at all. Logging and `/timestamps` still work — turn off logging separately with `LOG=0`. |

`notice` and `inline` are mutually exclusive; `MODE` picks one.

## Configuration

Config lives in a plain `KEY=value` file, one key per line, no quoting or JSON:

```
${CLAUDE_TIMESTAMPS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/claude-timestamps}/config.env
```

By default that is `~/.claude/claude-timestamps/config.env`.

| Key | Values | Default | Meaning |
| --- | --- | --- | --- |
| `MODE` | `notice`, `inline`, `off` | `notice` | How (and whether) the visible stamp is shown. |
| `FORMAT` | `clock`, `iso`, `relative` | `clock` | `clock` is `HH:MM:SS`; `iso` is a full ISO-8601 instant; `relative` is elapsed time since the session started. |
| `SHOW_DURATION` | `1`, `0` | `1` | Append how long the turn took to the stamp. |
| `LOG` | `1`, `0` | `1` | Write the per-message log under `sessions/`. Independent of `MODE`. |

Two environment variables matter:

- `CLAUDE_TIMESTAMPS_DIR` — override the whole state directory (config, logs).
- `CLAUDE_CONFIG_DIR` — respected if you have moved your Claude Code config elsewhere.

State is one JSONL file per session under `<state dir>/sessions/`. Files older than seven
days are removed at session start. Nothing outside that directory is touched.

## /timestamps

```
/timestamps                       # timeline of the current session
/timestamps --durations           # add per-turn elapsed times
/timestamps --format=iso          # clock (default) | iso | relative
/timestamps --last 10             # only the last N turns
/timestamps --json                # machine-readable output
/timestamps --session <id>        # a different session by id
/timestamps --file <path>         # a transcript JSONL path directly
```

The command reads the transcript JSONL that Claude Code already writes, so it works on
sessions from before the plugin was installed and does not depend on the log. It needs
Node 18 or newer on `PATH`; if `node` is missing it prints a single-line error and stops
without failing your session.

## Limitations

- **One stamp per turn, not per message.** The `Stop` hook fires once per user prompt. If
  the assistant sends several messages inside a single turn, they share one visible stamp.
  Per-message times exist only in the log and in `/timestamps` output.
- **The `MessageDisplay` hook needs a recent CLI.** On older builds the event is unknown,
  and an unknown event key disables every hook in the file that names it. That is why
  `MessageDisplay` lives alone in `hooks/messages.json` — on an older CLI you lose the
  per-message log and nothing else. The per-turn stamp and `/timestamps` keep working.
- **Desktop rendering.** See "What you'll actually see". The stamp is behind a dropdown
  there and this plugin cannot change that.
- **No message text is ever stored.** The log records identifiers, indices, timings and
  lengths. It does not record what you or the assistant wrote. `/timestamps` reads the
  transcript for structure but prints times, not content.
- **`inline` mode is advisory.** It is a request to the model, and models do not always
  comply.

## Uninstall

```
/plugin uninstall claude-timestamps@claude-timestamps
/plugin marketplace remove claude-timestamps
```

Then restart Claude Code. State and config are left in place; remove them yourself if you
want them gone:

```
rm -rf ~/.claude/claude-timestamps
```

## Licence

MIT. See [LICENSE](LICENSE). Contributor-facing notes on why the plugin is built the way
it is are in [DESIGN.md](DESIGN.md).
