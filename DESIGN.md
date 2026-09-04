# Design notes

This file is for contributors. The README says what the plugin does; this says why it is
built the way it is. Most of what follows is a constraint we hit and worked around, not a
preference. Please read the relevant section before changing a hook.

## Hook events: the published list is not the accepted list

The public hook documentation lists nine events. The CLI validates the event keys in a
hooks file against an internal enum that, in the build this plugin was developed against,
holds thirty-one names. `MessageDisplay` — the event that gives us per-message timing —
is one of the twenty-two that are accepted but not documented.

That gap is the central design fact of this plugin. We depend on a name that carries no
compatibility promise: it may be renamed, its payload may change shape, or it may not
exist at all in the CLI a user is running. Everything below is a consequence of deciding
to use it anyway, but to make its absence a non-event.

Two rules follow for anyone adding a hook:

1. If an event is documented, use it, and it is safe to put it alongside other hooks.
2. If it is not documented, it is quarantined (see the two-file split) and the plugin must
   behave correctly when it never fires.

## Why `MessageDisplay` is log-only

`MessageDisplay` fires once per assistant message and its stdin carries `turn_id`,
`message_id`, `index`, `final` and `delta`, where `delta` holds the assistant's own text.
It is the only event with true per-message granularity, which is exactly what a timestamp
plugin wants.

Its output is discarded. Not ignored-unless-well-formed — discarded. Nothing a
`MessageDisplay` hook prints on stdout can ever reach the screen, in any client, in any
form. So it cannot be the visible stamp. It can only write to disk, and that is all it
does here.

It also must not write everything it is given. `delta` is assistant text; a plugin that
logs it turns a timing log into a full shadow transcript in a directory the user did not
opt into. We record `length(delta)` and drop the string. The same rule applies to
`UserPromptSubmit`'s `prompt` field and to `Stop`'s `last_assistant_message`: their
existence is logged, their content is not.

The visible stamp therefore comes from `Stop`, whose `systemMessage` is the one channel a
hook has for putting text in front of the user — which is also why the README leads with
the fact that the terminal and the desktop app present that channel differently. Plain
stdout from a `Stop` hook renders nothing: the renderer maps that result to null.

## Why the hooks are split across two files

`plugin.json` names one hook file, and gets a second for free:

```json
"hooks": ["./hooks/messages.json"]
```

`hooks/hooks.json` is **not** listed, and must not be: the CLI loads that path automatically
by convention, so a manifest that also names it is rejected as a duplicate — "Duplicate
hooks file detected" — and the whole plugin's status becomes "failed to load". The `hooks`
array is for *additional* hook files only. This bit us: 0.1.2 listed both paths and was
dead on arrival on every CLI carrying the check, including the one bundled in the desktop
app, and `claude plugin validate --strict` passes either form, so only `claude plugin list`
surfaces it. Run it after any manifest change.

An unrecognised event key does not merely disable that one entry. It disables **every**
hook in the file that contains it. When `plugin.json` gives `hooks` as an array of files,
that failure is contained within one file.

So the split is a blast radius, not organisation:

- `hooks/hooks.json` holds `Stop`, `UserPromptSubmit` and `SessionStart` — all documented,
  all supported everywhere. This file is expected never to fail to load.
- `hooks/messages.json` holds `MessageDisplay` and nothing else. On a CLI that does not
  know the event, this file is discarded whole, the user loses the per-message log, and
  the visible stamp plus `/timestamps` are untouched.

Merging the two, or adding an undocumented event to `hooks.json`, silently turns a
degraded feature into a completely dead plugin on older CLIs. Do not do it. If you add
another unpublished event, give it a third file.

The array form matters for a second reason: hook files require the `{"hooks": {...}}`
wrapper, whereas an inline `hooks` value in `plugin.json` is the bare event map. The two
shapes are not interchangeable, and a wrapper in the wrong place is another silent
non-load.

A plugin whose only hooks live in `hooks/hooks.json` should omit the `hooks` key entirely
and let the auto-load handle it.

Every entry sets `"timeout": 5`. The default command-hook timeout is 600 seconds, which
for a hook that runs on every turn is not a timeout at all — it is a way to hang a session
for ten minutes on a wedged subprocess.

## Validating the manifests

Both manifests live in `.claude-plugin/`, so the obvious command validates the wrong one:

```
claude plugin validate . --strict                          # marketplace.json only
claude plugin validate .claude-plugin/plugin.json --strict  # plugin.json
```

The directory form resolves to `marketplace.json` and prints "Validating marketplace
manifest"; it never opens `plugin.json`. The two invocations are not redundant. Run both,
and read the line each one prints to confirm which file it looked at. CI runs both.

## Why a status of 2 is forbidden

On `Stop`, a hook exiting with status 2 means "do not stop". The agent takes another turn.
That hook fires again on the next stop, exits 2 again, and the session loops without a
user in it, burning tokens until someone interrupts it.

Nothing about that failure is visible. Every `Stop`-hook failure renders as nothing, so a
broken hook is silently broken for as long as it stays installed.

The trap is that you do not have to write the number to produce it. A shell script with a
syntax error exits with status 2. So does a script that trips over an unset variable under
the wrong options. That means the dangerous exit status is the *default* outcome of an
ordinary typo, and the safe one has to be made unconditional:

- Every hook script ends with a literal `exit 0`, and has no other exit path.
- No `set -e`. It converts any non-zero command into an early, uncontrolled exit.
- Real work runs in a subshell whose failure is swallowed:
  `out=$( real_work 2>/dev/null ) || out=""`.
- The captured output is checked for blocking control keys before it is printed, so a
  malformed payload cannot cause the hook to emit something that changes the agent's
  behaviour. Emitting a stamp is the only effect this plugin is allowed to have.
  That check is applied twice, and the order matters. `emit` tests the **raw** text
  before `ts_escape` runs: once escaping has rewritten every `"` as `\"`, a control key
  in the text can no longer match a pattern written with literal quotes, and a guard
  placed after it can never fire. The second check, in each hook script, tests the
  finished JSON, where those quotes are real — that one catches a key we emitted
  ourselves. The stronger guarantee is still structural: `emit` writes one hardcoded key
  through `printf`, so there is no path by which a second key appears.
- CI greps the whole tree for those control-key strings and for a literal status-2 exit,
  and fails the build if any appears. This is why the docs describe them in prose rather
  than quoting them: a code fence would fail CI.

Status 1 is the safe non-zero: non-blocking, no loop.

## Why nothing forks an interpreter, and nothing reads the transcript

Measured on the development machine:

| Operation | Cost |
| --- | --- |
| fork `node` | 24.00 ms |
| fork `python3` | 15.16 ms |
| fork `date` | 1.75 ms |
| scan a 165 MB transcript JSONL | 131 ms |

And the shipped hooks themselves, 100 runs each on the test fixtures, macOS 26 / bash 3.2:

| Invocation | Cost |
| --- | --- |
| `bash -c 'exit 0'` (interpreter startup alone) | 2.2 ms |
| `hooks/stop.sh` | 9.3 ms |
| `hooks/user-prompt-submit.sh` | 9.9 ms |
| `hooks/message-display.sh` | 9.0 ms |
| `hooks/message-display.sh`, 48 KB `delta` | 13.4 ms |
| `hooks/session-start.sh` | 10.8 ms |

So the real per-turn cost is `UserPromptSubmit` + `Stop` ≈ **19 ms**, plus about 9 ms for
each assistant message in the turn, since `MessageDisplay` fires per message and not per
turn. Under 10 ms per turn is not reachable with two shell hooks: two `bash` startups is
4.4 ms of the budget before either script runs a line, and each hook also forks `cat` and
`date`. Treat 10 ms as the per-hook order of magnitude to defend, not a per-turn total.

What the budget does rule out is unbounded work. Both interpreters cost more than a whole
hook before running a line of their own code, so the per-turn hooks are POSIX shell, they
get the time from `date`, and they pull the two or three fields they need out of stdin
with parameter expansion. `jq` is used when `command -v jq` finds it and the payload is
large enough to be worth a fork; it is never a requirement. `node` is not guaranteed on
`PATH` under the native installer, and `python3` is not present on every Linux, so neither
can be a hard dependency of a hook.

The transcript is never opened by a hook. It grows without bound, a large one costs 131 ms
to scan, and that cost lands on every single turn. Reading it is the job of
`/timestamps`, which runs once, on demand, in Node, where 24 ms of startup is irrelevant.

One `date` caveat: BSD `date` on macOS 26 accepts `%N` but rejects `%3N` and `%6N`. Check
the digit shape of what came back rather than assuming the format string was honoured.

## Why the payload is shrunk before it is parsed

`${var#*pat}` and `${var%%pat*}` are **quadratic** in the length of `var`: the shell
retries the match at every prefix length. That is invisible on a 500-byte payload and
fatal on a large one. Measured on the original code, reading three short ids out of a
48 KB `MessageDisplay` payload took 1.5 s, and 128 KB ran past the 5 s hook timeout — at
which point the host kills the hook and, because every `Stop`-hook failure renders as
nothing, the stamp simply stops appearing.

Payload size is not ours to choose. `delta` carries a whole assistant message and
`last_assistant_message` carries the whole reply, so a long answer is a large payload. Nor
is key order ours to choose: JSON objects have no ordering guarantee, and the same payload
with `last_assistant_message` moved to the front went from 12 ms to 2.3 s, because the
fields we read then sat behind it.

So `ts_prepare_payload` runs once, before any field is read, and replaces a payload larger
than `TS_SCAN_MAX` (1 KB) with a small equivalent:

- **With `jq`:** one fork projects out just the fields the four hooks read, each string
  clamped, plus `length(delta)`. Correct whatever the key order, and the assistant's text
  never enters the shell at all.
- **Without `jq`:** the first `TS_SCAN_MAX` bytes, and `TS_TRUNCATED=1`. Fields that would
  have sat beyond the cut read as missing — the ids degrade to `unknown` — rather than
  costing seconds. `delta_len` is then recorded as `-1`, meaning "not measurable", which
  is not the same as `0`.

`ts_json_get` keeps two guards of its own for anything that reaches it another way: the
`jq` path above `TS_SCAN_MAX`, and a hard refusal above `TS_SCAN_HARD` (4 KB). An empty
field is a much better outcome than a hook the host kills.

The cost is bounded either way: a 2 MB payload now costs about 50 ms with `jq` and about
40 ms without it, against 5 s of timeout.

The same reasoning applies to `config.env`, which lives in a directory this plugin does
not own. `ts_load_config` requires a **regular file** — opening a FIFO blocks forever and
burns the whole timeout on every event, and anything that can write to the state directory
can leave one there — and it stops after 64 lines and ignores lines longer than 64
characters. No legal line is longer than `SHOW_DURATION=1`.

## Why state is one file per session

The obvious design — one append-only log for everything — corrupts. Concurrent `>>`
appends were measured interleaving and producing torn records once records reached 1024
bytes. Sessions genuinely do run in parallel: several terminals, the desktop app, and
subagents within one session all fire hooks at once.

Locking is not a good answer here. `flock(1)` does not exist on macOS, so a portable lock
means `mkdir` or `set -C`, which is another fork and another failure mode on every turn,
in a hook that costs about 9 ms in total.

The answer is to remove the contention instead. One file per session, named by the
sanitised session id, means two writers never target the same path. Within a session,
records are written to a temporary file and renamed into place; the temporary file is
created **in the destination directory**, because `mv` is atomic only within a single
filesystem. Under this scheme, 800 concurrent writes produced zero corruption.

Supporting rules:

- `umask 077` at the top of every hook. These files describe a user's working patterns.
- The session id is sanitised before it touches a path — anything outside
  `[A-Za-z0-9._-]` makes the whole id `unknown`. It arrives as JSON from the host, and a
  path is not a place to find out that it contained a slash.
- Garbage collection happens only at `SessionStart`, only via a `find` with `-maxdepth 1`,
  `-type f`, `-name '*.jsonl'` and `-mtime +7`. The state directory is never removed
  recursively. A GC bug should cost someone a week of timing logs, not their home
  directory.
- `${CLAUDE_PLUGIN_ROOT}` may carry a trailing slash, so it is always quoted and never
  string-compared. Durable state goes under the configured state directory (or
  `${CLAUDE_PLUGIN_DATA}`), which survives plugin updates; the plugin root does not.
- `CLAUDE_CODE_SESSION_ID` is exported to subprocesses and can be relied on.
  `CLAUDE_PROJECT_DIR` is not reliably set for Bash-tool subprocesses in desktop sessions,
  so nothing depends on it.

## Why the renderer never computes a slug

Session transcripts live at `~/.claude/projects/<project-slug>/<session-id>.jsonl`, where
the slug is derived from the project's working directory by a mangling rule. It is
tempting to reconstruct the slug from `cwd` and open the file directly.

Do not. The mangling is not documented, it has changed between releases, and it does not
round-trip: symlinked paths, non-ASCII characters, trailing slashes and worktrees all
produce a slug that does not match what a naive transformation yields. Getting it wrong
gives "no such session" for a session that is sitting right there.

The session id, by contrast, is exact and is handed to us. So the renderer globs
`~/.claude/projects/*/<session-id>.jsonl` (honouring `CLAUDE_CONFIG_DIR`) and takes the
match. `--session` and `--file` exist for the cases where the caller already knows better.

## Renderer parsing notes

The transcript format is an open enum with entries this plugin does not care about, so the
renderer is written to skip rather than to fail:

- A human turn is `type === 'user'` with `origin?.kind === 'human'`, a `promptSource` of
  `typed` or `queued`, `isSidechain !== true`, and no `isMeta`. Anything else is not a
  user turn, whatever it looks like.
- Turns are segmented by `promptId`. A turn's duration is the newest timestamp sharing
  that `promptId` minus the prompt's own timestamp. For a queued prompt, "typed at" comes
  from the matching queue-operation enqueue entry, not from the point it was dequeued.
- Assistant lines are grouped into one reply by `requestId ?? message.id ?? uuid`.
- Excluded: sidechains, entries with `sourceToolAssistantUUID`, entries whose
  `message.content[0].type === 'tool_result'`, `isMeta` entries, `type === 'attachment'`,
  and text matching `/^\[Request interrupted by user/` or starting with `<command-name>`,
  `<local-command-stdout>`, `<bash-input>`, `<bash-stdout>` or `<local-command-caveat>`.
- A record carrying a `promptId` extends the turn that owns that `promptId`, and nothing
  else. If no turn owns it, the prompt it belongs to has not been read yet — slash-command
  echoes, `/model` switches and resume stubs are all written ahead of their own prompt
  record — so it extends nothing. Letting those fall through to whichever turn was open
  hands the previous turn an end timestamp from days later: on the development corpus,
  59 of 2,041 turns were affected, the worst reporting 118 hours for ten minutes of work.
- A prompt that matches only the widened predicate is not shown as a row of its own when
  the strict predicate matched anything, but it is not discarded either: it was `open`
  while it ran, so its span and its replies are folded into the preceding kept turn.
  Dropping the object deletes real assistant activity from the timeline with no marker.
- Prompt previews strip C0 control characters before collapsing whitespace. `\s` does not
  cover ESC, BEL or BS, and the preview is written straight to a terminal — an escape
  sequence in a prompt somebody once pasted could clear the screen, rewrite the lines
  above it, or emit an OSC-8 hyperlink pointing anywhere.
- Entries are deduplicated by `uuid`; genuine duplicates exist in real transcripts.
- An unknown `type` is skipped silently. New entry kinds appear in new releases and must
  not be an error.
- `system` / `compact_boundary` entries render as a divider, and duration accounting is
  broken across one — the wall-clock gap across a compaction is not turn time.
- `apiBlockIndex` exists only from 2.1.258, and `turn_duration` is sometimes missing and
  sometimes over-counts. Neither is used.

## Adding a feature

Before you open a PR, check your change against these:

1. Does it add an unconditional fork to a per-turn hook? A hook is about 9 ms today and
   `node` alone is 24. A fork taken only on a large payload, to keep a cost bounded, is a
   different thing from one taken on every turn.
2. Does it read the transcript from a hook? That is 131 ms on a large session, every turn.
3. Does it put an undocumented event in a file with documented ones?
4. Can any path through it exit with a status other than 0 from a hook script?
5. Does it write user or assistant text to disk?
6. Does it emit anything on `Stop` other than a single-line `systemMessage`? The
   `Stop says:` prefix is applied per line, so an embedded newline produces a second
   prefixed line.
7. Does a hook read a payload field that `TS_JQ_PROJECT` in `hooks/lib.sh` does not
   name? On a large payload the projection is the payload, so an unlisted field reads as
   empty and the hook degrades in silence. Add the field there in the same change.
8. Did you bump `version` in `.claude-plugin/plugin.json`? Installed users are updated on
   a version change and on nothing else.

A "yes" to 1-6 is a blocker, and so is a "yes" to 7. A "no" to 8 means the fix ships to
nobody.

The install cache is keyed by that version: it lives at
`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`, and
`claude plugin marketplace update` reports success while leaving an unchanged version's
cached copy exactly as it was. While developing locally, `claude plugin uninstall`
followed by `claude plugin install` is the only reliable way to see your edit run.
