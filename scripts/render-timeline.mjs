#!/usr/bin/env node
// claude-timestamps — the /timestamps renderer.
//
// Reads a Claude Code session transcript (JSONL) and prints a timestamped
// timeline of the human turns in it. Node >= 18, zero dependencies.
//
// Transcripts are append-only JSONL and can reach hundreds of megabytes, so
// this streams line by line and never holds the file in memory. Every line is
// parsed defensively: unparseable lines are dropped, unknown `type` values are
// ignored, and no malformed record is allowed to throw.
//
// Style note: this file deliberately avoids the `contin`+`ue` keyword. That
// string is forbidden tree-wide (it is a hook-output field that can hang an
// agent) and CI greps for it, so loop bodies are written as functions whose
// early `return` does the same job.

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import readline from 'node:readline';

const PROG = 'timestamps';

// A prompt is only reported as "queued" if it sat in the queue at least this
// long. Every prompt is enqueued a few milliseconds before it runs.
const QUEUE_MIN_MS = 1000;

// ---------------------------------------------------------------------------
// Node version gate
// ---------------------------------------------------------------------------

function nodeTooOld() {
  const major = Number.parseInt(String(process.versions.node).split('.')[0], 10);
  return !Number.isFinite(major) || major < 18;
}

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------

const USAGE = `Usage: render-timeline.mjs [options]

  --session <id>   Session to render (default: $CLAUDE_CODE_SESSION_ID)
  --file <path>    Render this transcript file directly
  --last <n>       Show only the last n turns
  --format <fmt>   clock (default) | iso | relative
  --durations      Add time-to-first-reply and turn end time
  --json           Emit JSON instead of a table
  -h, --help       This message
`;

function parseArgs(argv) {
  const opt = {
    session: process.env.CLAUDE_CODE_SESSION_ID || '',
    sessionExplicit: false,
    file: '',
    last: 0,
    format: 'clock',
    durations: false,
    json: false,
    help: false,
    error: '',
  };

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a !== '--') {
      let key = a;
      let inline = null;
      const eq = a.indexOf('=');
      if (a.startsWith('--') && eq > 2) {
        key = a.slice(0, eq);
        inline = a.slice(eq + 1);
      }
      const next = () => (inline !== null ? inline : argv[++i]);

      switch (key) {
        case '-h':
        case '--help':
          opt.help = true;
          break;
        case '--json':
          opt.json = true;
          break;
        case '--durations':
          opt.durations = true;
          break;
        case '--session':
          opt.session = String(next() ?? '').trim();
          opt.sessionExplicit = true;
          break;
        case '--file':
          opt.file = String(next() ?? '').trim();
          break;
        case '--format': {
          const v = String(next() ?? '')
            .trim()
            .toLowerCase();
          if (v !== 'clock' && v !== 'iso' && v !== 'relative') {
            opt.error = `unknown --format "${v}" (want clock, iso or relative)`;
          } else {
            opt.format = v;
          }
          break;
        }
        case '--last': {
          const v = Number.parseInt(String(next() ?? ''), 10);
          if (!Number.isFinite(v) || v <= 0) {
            opt.error = '--last needs a positive whole number';
          } else {
            opt.last = v;
          }
          break;
        }
        default:
          if (a.startsWith('-')) {
            opt.error = `unknown option "${a}"`;
          } else if (!opt.sessionExplicit) {
            opt.session = a; // a bare word is taken as a session id
            opt.sessionExplicit = true;
          }
      }
    }
  }
  return opt;
}

// ---------------------------------------------------------------------------
// Locating the transcript
// ---------------------------------------------------------------------------

function expandHome(p) {
  if (p === '~') return os.homedir();
  if (p.startsWith('~/')) return path.join(os.homedir(), p.slice(2));
  return p;
}

function configDir() {
  const c = process.env.CLAUDE_CONFIG_DIR;
  if (c && c.trim()) return expandHome(c.trim());
  return path.join(os.homedir(), '.claude');
}

// Transcripts live at <config>/projects/<slug>/<session_id>.jsonl.
//
// The slug is derived from the directory the session STARTED in, which is not
// necessarily the directory we are running in now: git worktrees, resumed
// sessions and desktop-app sessions all break that assumption. So we never
// compute a slug from cwd — we look for the session id in every project
// directory instead.
//
// Subagent transcripts sit one level deeper, at
// <slug>/<session_id>/subagents/agent-*.jsonl, and reuse the parent's session
// id. Matching only <slug>/<session_id>.jsonl keeps us on the main thread.
function findTranscripts(sessionId) {
  const root = path.join(configDir(), 'projects');
  const hits = [];
  if (!/^[A-Za-z0-9._-]+$/.test(sessionId)) return hits;

  let entries;
  try {
    entries = fs.readdirSync(root, { withFileTypes: true });
  } catch {
    return hits;
  }

  for (const e of entries) {
    if (e.isDirectory()) {
      const f = path.join(root, e.name, `${sessionId}.jsonl`);
      let st = null;
      try {
        st = fs.statSync(f);
      } catch {
        st = null;
      }
      if (st && st.isFile()) hits.push({ file: f, mtime: st.mtimeMs, size: st.size });
    }
  }

  // One session id can appear under several slugs (a worktree session resumed
  // from another directory). Newest wins.
  hits.sort((a, b) => b.mtime - a.mtime);
  return hits;
}

// ---------------------------------------------------------------------------
// Record classification
// ---------------------------------------------------------------------------

const COMMANDISH = [
  '<command-name>',
  '<local-command-stdout>',
  '<local-command-stderr>',
  '<bash-input>',
  '<bash-stdout>',
  '<bash-stderr>',
  '<local-command-caveat>',
];

function textOf(rec) {
  const msg = rec && rec.message;
  const c = msg && msg.content;
  if (typeof c === 'string') return c;
  if (Array.isArray(c)) {
    const parts = [];
    for (const b of c) {
      if (b && b.type === 'text' && typeof b.text === 'string') parts.push(b.text);
    }
    return parts.join('\n');
  }
  return '';
}

function firstBlockType(rec) {
  const c = rec && rec.message && rec.message.content;
  if (Array.isArray(c) && c.length && c[0] && typeof c[0].type === 'string') {
    return c[0].type;
  }
  return '';
}

// User-shaped records that are not a person speaking.
function isExcluded(rec) {
  if (!rec || typeof rec !== 'object') return true;
  if (rec.isSidechain === true) return true;
  if (rec.isMeta) return true;
  if (rec.type === 'attachment') return true;
  if (rec.sourceToolAssistantUUID) return true;
  if (firstBlockType(rec) === 'tool_result') return true;
  const t = textOf(rec);
  if (t) {
    if (/^\[Request interrupted by user/.test(t)) return true;
    for (const p of COMMANDISH) {
      if (t.startsWith(p)) return true;
    }
  }
  return false;
}

// The human-turn predicate. Terminal sessions record prompts as 'typed' or,
// when the user got ahead of the model, 'queued'.
function isHumanTurn(rec) {
  return (
    rec.type === 'user' &&
    rec.origin &&
    rec.origin.kind === 'human' &&
    (rec.promptSource === 'typed' || rec.promptSource === 'queued') &&
    rec.isSidechain !== true &&
    !rec.isMeta &&
    !isExcluded(rec)
  );
}

// Desktop-app and SDK-driven sessions record the very same human prompts with
// promptSource === 'sdk'. They are still origin.kind === 'human', so when a
// transcript holds no typed/queued prompts at all we widen to those rather
// than print an empty timeline. The widening is stated in the header.
function isWidenedHumanTurn(rec) {
  return (
    rec.type === 'user' &&
    rec.origin &&
    rec.origin.kind === 'human' &&
    typeof rec.promptSource === 'string' &&
    rec.isSidechain !== true &&
    !rec.isMeta &&
    !isExcluded(rec)
  );
}

// One reply = one API response. Assistant records carry no promptId, so they
// are attributed to whichever turn is open when they appear.
function replyKey(rec) {
  return rec.requestId || (rec.message && rec.message.id) || rec.uuid || '';
}

function tsOf(rec) {
  const t = rec && rec.timestamp;
  if (typeof t !== 'string') return NaN;
  const ms = Date.parse(t);
  return Number.isFinite(ms) ? ms : NaN;
}

// ---------------------------------------------------------------------------
// Scan
// ---------------------------------------------------------------------------

async function scan(file) {
  const turns = [];
  const dividers = [];
  const enqueues = []; // { ts, content }
  const seenUuid = new Set();
  const byPromptId = new Map();

  let segment = 0; // increments at every compact boundary
  let open = null; // the turn currently accumulating
  let lines = 0;
  let dropped = 0;
  let sawTypedOrQueued = false;

  const startTurn = (rec, widened) => {
    const start = tsOf(rec);
    const turn = {
      n: 0,
      promptId: typeof rec.promptId === 'string' ? rec.promptId : '',
      uuid: rec.uuid || '',
      promptSource: rec.promptSource || '',
      widened,
      segment,
      start,
      end: start,
      firstReply: NaN,
      enqueued: NaN,
      replies: new Set(),
      replyCount: 0,
      text: textOf(rec),
      cwd: typeof rec.cwd === 'string' ? rec.cwd : '',
      gitBranch: typeof rec.gitBranch === 'string' ? rec.gitBranch : '',
    };
    turns.push(turn);
    if (turn.promptId) byPromptId.set(turn.promptId, turn);
    open = turn;
  };

  // Duration accounting does not cross a compact boundary: a turn that was
  // still open when the context was compacted stops accumulating there.
  const extend = (turn, ms) => {
    if (!turn || !Number.isFinite(ms)) return;
    if (turn.segment !== segment) return;
    if (!Number.isFinite(turn.end) || ms > turn.end) turn.end = ms;
  };

  const handleRecord = (rec) => {
    // Duplicate records do occur in transcripts.
    if (typeof rec.uuid === 'string' && rec.uuid) {
      if (seenUuid.has(rec.uuid)) return;
      seenUuid.add(rec.uuid);
    }

    const ms = tsOf(rec);

    if (rec.type === 'queue-operation') {
      if (rec.operation === 'enqueue' && typeof rec.content === 'string') {
        enqueues.push({ ts: ms, content: rec.content });
      }
      return;
    }

    if (rec.type === 'system') {
      if (rec.subtype === 'compact_boundary') {
        segment++;
        open = null;
        const meta = rec.compactMetadata || {};
        dividers.push({
          at: turns.length,
          ts: ms,
          trigger: typeof meta.trigger === 'string' ? meta.trigger : '',
          preTokens: Number.isFinite(meta.preTokens) ? meta.preTokens : null,
        });
      }
      return;
    }

    if (rec.type === 'user') {
      if (isHumanTurn(rec)) {
        sawTypedOrQueued = true;
        startTurn(rec, false);
      } else if (isWidenedHumanTurn(rec)) {
        startTurn(rec, true);
      } else if (typeof rec.promptId === 'string' && rec.promptId) {
        // Tool results and other machinery carry the turn's promptId, so they
        // extend the turn that owns it — and nothing else. A promptId we have
        // not seen a prompt for belongs to a turn that has not started yet:
        // slash-command echoes, /model switches and resume stubs are all
        // written ahead of their own prompt record. Letting those fall through
        // to the open turn hands the previous turn an end timestamp from
        // hours or days later (measured: a turn of 10m reported as 118h).
        const owner = byPromptId.get(rec.promptId);
        if (owner) extend(owner, ms);
      } else {
        extend(open, ms);
      }
      return;
    }

    if (rec.type === 'assistant') {
      if (rec.isSidechain === true || rec.sourceToolAssistantUUID) return;
      if (open) {
        const k = replyKey(rec);
        if (k && !open.replies.has(k)) {
          open.replies.add(k);
          if (!Number.isFinite(open.firstReply) && Number.isFinite(ms)) {
            open.firstReply = ms;
          }
        }
        extend(open, ms);
      }
      return;
    }

    // Open enum: any other type just extends the open turn's span if it is
    // timestamped, and is otherwise ignored.
    if (rec.isSidechain !== true) extend(open, ms);
  };

  let stream;
  try {
    stream = fs.createReadStream(file, { encoding: 'utf8' });
  } catch {
    return null;
  }
  const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });

  try {
    for await (const line of rl) {
      lines++;
      // Cheap pre-filter: every real record is a JSON object.
      if (line && line.charCodeAt(0) === 123 /* { */) {
        let rec = null;
        try {
          rec = JSON.parse(line);
        } catch {
          rec = null;
          dropped++;
        }
        if (rec && typeof rec === 'object') handleRecord(rec);
      }
    }
  } catch {
    // A truncated or unreadable tail is not fatal: render what we have.
  } finally {
    try {
      rl.close();
    } catch {
      /* already closed */
    }
  }

  // If the strict predicate matched anything, the widened turns are not shown
  // as rows of their own, so that a terminal session is never polluted by
  // SDK-origin records. They are not simply discarded, though: a widened turn
  // was `open` while it ran, so it has already absorbed its own assistant
  // replies and its own span. Dropping the object would delete that activity
  // from the timeline entirely — replies uncounted, a gap with no marker, and
  // the preceding turn's end left short. So its span and replies are folded
  // into the preceding kept turn instead.
  let kept = turns;
  let widened = false;
  if (sawTypedOrQueued) {
    kept = [];
    let prev = null;
    for (const t of turns) {
      if (t.widened) {
        if (prev && prev.segment === t.segment) {
          if (Number.isFinite(t.end) && (!Number.isFinite(prev.end) || t.end > prev.end)) {
            prev.end = t.end;
          }
          for (const k of t.replies) prev.replies.add(k);
          if (!Number.isFinite(prev.firstReply) && Number.isFinite(t.firstReply)) {
            prev.firstReply = t.firstReply;
          }
        }
      } else {
        kept.push(t);
        prev = t;
      }
    }
  } else {
    widened = turns.some((t) => t.widened);
  }

  // A queued prompt was typed before it ran. Pair each turn with its enqueue
  // record by content, first unused match wins.
  if (enqueues.length) {
    const used = new Set();
    for (const t of kept) {
      const want = (t.text || '').trim();
      if (want) {
        const i = enqueues.findIndex(
          (e, idx) =>
            !used.has(idx) &&
            typeof e.content === 'string' &&
            e.content.trim() === want &&
            !(Number.isFinite(e.ts) && Number.isFinite(t.start) && e.ts > t.start)
        );
        if (i >= 0) {
          used.add(i);
          t.enqueued = enqueues[i].ts;
        }
      }
    }
  }

  kept.forEach((t, i) => {
    t.n = i + 1;
    t.replyCount = t.replies.size;
    delete t.replies;
    if (!Number.isFinite(t.end) || !Number.isFinite(t.start) || t.end < t.start) {
      t.end = t.start;
    }
  });

  // Dividers were recorded against the unfiltered turn list; remap them onto
  // the kept list so they land between the right rows.
  const indexOfKept = new Map();
  kept.forEach((t, i) => indexOfKept.set(t, i));
  const remapped = dividers.map((d) => {
    let after = 0;
    for (const t of kept) {
      if (Number.isFinite(t.start) && Number.isFinite(d.ts) && t.start < d.ts) {
        after = indexOfKept.get(t) + 1;
      }
    }
    return { at: after, ts: d.ts, trigger: d.trigger, preTokens: d.preTokens };
  });

  return { file, turns: kept, dividers: remapped, lines, dropped, widened };
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

function pad2(n) {
  return String(n).padStart(2, '0');
}

function clock(ms) {
  if (!Number.isFinite(ms)) return '--:--:--';
  const d = new Date(ms);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
}

function isoStamp(ms) {
  if (!Number.isFinite(ms)) return '(no timestamp)';
  return new Date(ms).toISOString();
}

function dateOf(ms) {
  if (!Number.isFinite(ms)) return '';
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

function relStamp(ms, origin) {
  if (!Number.isFinite(ms) || !Number.isFinite(origin)) return '--:--:--';
  let s = Math.max(0, Math.round((ms - origin) / 1000));
  const h = Math.floor(s / 3600);
  s -= h * 3600;
  const m = Math.floor(s / 60);
  s -= m * 60;
  return `+${pad2(h)}:${pad2(m)}:${pad2(s)}`;
}

function stampFn(format, origin) {
  if (format === 'iso') return (ms) => isoStamp(ms);
  if (format === 'relative') return (ms) => relStamp(ms, origin);
  return (ms) => clock(ms);
}

function duration(msSpan) {
  if (!Number.isFinite(msSpan) || msSpan < 0) return '-';
  if (msSpan < 1000) return `${Math.max(0, Math.round(msSpan))}ms`;
  const total = Math.round(msSpan / 1000);
  if (total < 60) return `${total}s`;
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) return `${h}h ${pad2(m)}m`;
  return `${m}m ${pad2(s)}s`;
}

function preview(text, width) {
  let t = String(text || '');
  t = t.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, ' ');
  // Control characters, before the whitespace collapse — \s does not cover
  // ESC, BEL or BS. This text is a prompt somebody once pasted, and it is
  // about to be written to a terminal: an ESC sequence in it could clear the
  // screen, rewrite lines above, or emit an OSC-8 hyperlink to anywhere.
  t = t.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, ' ');
  t = t.replace(/\s+/g, ' ').trim();
  if (!t) return '(no text)';
  if (t.length <= width) return t;
  if (width <= 1) return t.slice(0, Math.max(0, width));
  return `${t.slice(0, width - 1).trimEnd()}…`;
}

function termWidth() {
  const c = process.stdout && process.stdout.columns;
  if (Number.isFinite(c) && c >= 40) return Math.min(c, 200);
  return 100; // not a TTY: assume a fixed width so captured output still lines up
}

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

function render(res, opt, out) {
  const all = res.turns;
  const origin = all.length ? all[0].start : NaN;
  const stamp = stampFn(opt.format, origin);

  let shown = all;
  let trimmed = 0;
  if (opt.last > 0 && all.length > opt.last) {
    trimmed = all.length - opt.last;
    shown = all.slice(trimmed);
  }

  const lines = [];
  lines.push(`session  ${res.sessionId || '(unknown)'}`);
  lines.push(`file     ${res.file}`);

  if (all.length === 0) {
    lines.push('');
    lines.push(`No human turns found in this transcript (${res.lines} records scanned).`);
    out(lines.join('\n'));
    return;
  }

  const last = all[all.length - 1];
  const day = dateOf(all[0].start);
  const dayEnd = dateOf(last.end);
  const dayLabel = day && dayEnd && day !== dayEnd ? `${day} → ${dayEnd}` : day;
  lines.push(
    `turns    ${all.length}${trimmed ? ` (showing last ${shown.length})` : ''}` +
      `   ${dayLabel}  ${clock(all[0].start)} → ${clock(last.end)}` +
      `   ${duration(last.end - all[0].start)} elapsed`
  );
  if (res.widened) {
    lines.push(
      'note     no typed/queued prompts in this transcript; showing origin=human ' +
        'prompts as recorded by the desktop app / SDK'
    );
  }
  if (res.dropped) {
    lines.push(`note     ${res.dropped} unparseable line(s) skipped`);
  }
  lines.push('');

  // Column widths.
  const wN = Math.max(1, String(last.n).length);
  const wStamp = opt.format === 'iso' ? 24 : 9;
  const wDur = Math.max(3, ...shown.map((t) => duration(t.end - t.start).length));
  const wRep = Math.max(3, ...shown.map((t) => String(t.replyCount).length));

  let head =
    '  ' +
    '#'.padStart(wN) +
    '  ' +
    'started'.padEnd(wStamp) +
    '  ' +
    'dur'.padStart(wDur) +
    '  ' +
    'rep'.padStart(wRep);

  let wFirst = 0;
  if (opt.durations) {
    const lat = shown.map((t) =>
      Number.isFinite(t.firstReply) ? duration(t.firstReply - t.start) : '-'
    );
    wFirst = Math.max(5, ...lat.map((l) => l.length));
    head += '  ' + 'first'.padStart(wFirst) + '  ' + 'ended'.padEnd(wStamp);
  }
  const wPrev = Math.max(20, termWidth() - (head.length + 2) - 1);
  head += '  ' + 'prompt';
  lines.push(head);

  const dividerAt = new Map();
  for (const d of res.dividers) {
    if (!dividerAt.has(d.at)) dividerAt.set(d.at, []);
    dividerAt.get(d.at).push(d);
  }

  const emitDividers = (idx) => {
    const ds = dividerAt.get(idx);
    if (!ds) return;
    for (const d of ds) {
      const bits = ['context compacted'];
      if (d.trigger) bits.push(d.trigger);
      if (Number.isFinite(d.preTokens)) {
        bits.push(`${d.preTokens.toLocaleString('en-US')} tokens`);
      }
      lines.push(`  ${'─'.repeat(wN)}  ${stamp(d.ts).padEnd(wStamp)}  ── ${bits.join(' · ')} ──`);
    }
  };

  emitDividers(trimmed);

  shown.forEach((t, i) => {
    // Only surface an enqueue time when the prompt actually waited: every
    // prompt is enqueued a few milliseconds before it runs.
    const queued = Number.isFinite(t.enqueued) && t.start - t.enqueued >= QUEUE_MIN_MS;
    const at = queued ? t.enqueued : t.start;

    let row =
      '  ' +
      String(t.n).padStart(wN) +
      '  ' +
      (stamp(at) + (queued ? '·q' : '')).padEnd(wStamp) +
      '  ' +
      duration(t.end - t.start).padStart(wDur) +
      '  ' +
      String(t.replyCount).padStart(wRep);

    if (opt.durations) {
      const lat = Number.isFinite(t.firstReply) ? duration(t.firstReply - t.start) : '-';
      row += '  ' + lat.padStart(wFirst) + '  ' + stamp(t.end).padEnd(wStamp);
    }
    row += '  ' + preview(t.text, wPrev);
    lines.push(row);

    if (queued) {
      lines.push(
        ' '.repeat(2 + wN) +
          `  ·q typed ${duration(t.start - t.enqueued)} earlier, ran at ${stamp(t.start)}`
      );
    }
    emitDividers(trimmed + i + 1);
  });

  lines.push('');
  lines.push(
    'dur = prompt to last activity in that turn.  rep = assistant replies.' +
      (opt.durations ? '  first = time to first reply.' : '')
  );
  out(lines.join('\n'));
}

function toJson(res, opt) {
  let turns = res.turns;
  if (opt.last > 0 && turns.length > opt.last) turns = turns.slice(turns.length - opt.last);
  const iso = (ms) => (Number.isFinite(ms) ? new Date(ms).toISOString() : null);
  return {
    session: res.sessionId || null,
    file: res.file,
    widenedPredicate: !!res.widened,
    recordsScanned: res.lines,
    unparseableLines: res.dropped,
    turns: turns.map((t) => ({
      n: t.n,
      promptId: t.promptId || null,
      uuid: t.uuid || null,
      promptSource: t.promptSource || null,
      start: iso(t.start),
      end: iso(t.end),
      enqueuedAt: iso(t.enqueued),
      firstReplyAt: iso(t.firstReply),
      durationMs: Number.isFinite(t.end - t.start) ? t.end - t.start : null,
      firstReplyMs: Number.isFinite(t.firstReply - t.start) ? t.firstReply - t.start : null,
      replies: t.replyCount,
      cwd: t.cwd || null,
      gitBranch: t.gitBranch || null,
      preview: preview(t.text, 200),
    })),
    compactions: res.dividers.map((d) => ({
      afterTurn: d.at,
      at: iso(d.ts),
      trigger: d.trigger || null,
      preTokens: d.preTokens,
    })),
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const say = (s) => process.stdout.write(`${s}\n`);

  if (nodeTooOld()) {
    say(`${PROG}: needs Node 18 or newer (found ${process.versions.node}).`);
    return;
  }

  const opt = parseArgs(process.argv.slice(2));

  if (opt.help) {
    say(USAGE.trimEnd());
    return;
  }
  if (opt.error) {
    say(`${PROG}: ${opt.error}`);
    return;
  }

  let file = '';
  let sessionId = opt.session;

  if (opt.file) {
    file = path.resolve(expandHome(opt.file));
    let ok = false;
    try {
      ok = fs.statSync(file).isFile();
    } catch {
      ok = false;
    }
    if (!ok) {
      say(`${PROG}: no readable transcript at ${file}`);
      return;
    }
    // --file wins outright: never label the file with an unrelated session id
    // inherited from $CLAUDE_CODE_SESSION_ID.
    if (!opt.sessionExplicit) sessionId = path.basename(file).replace(/\.jsonl$/, '');
  } else {
    if (!sessionId) {
      say(
        `${PROG}: no session id — CLAUDE_CODE_SESSION_ID is unset. ` +
          'Pass --session <id> or --file <path/to/transcript.jsonl>.'
      );
      return;
    }
    const hits = findTranscripts(sessionId);
    if (!hits.length) {
      say(
        `${PROG}: no transcript for session ${sessionId} under ` +
          `${path.join(configDir(), 'projects')}/*/. ` +
          'Pass --file <path> to point at one directly.'
      );
      return;
    }
    file = hits[0].file;
  }

  const res = await scan(file);
  if (!res) {
    say(`${PROG}: could not read ${file}`);
    return;
  }
  res.sessionId = sessionId;

  if (opt.json) {
    say(JSON.stringify(toJson(res, opt), null, 2));
    return;
  }
  render(res, opt, say);
}

// EPIPE is normal when the caller pipes this into `head`.
process.stdout.on('error', () => {});

// Note: no process.exit() on any path. Calling it discards stdout that is
// still buffered when output goes to a pipe or a file, which silently
// truncates large --json output. The event loop drains and the process exits 0
// on its own.
main().catch((err) => {
  // Never let an unexpected failure look like a crash to the user.
  const msg = err && err.message ? err.message : String(err);
  process.stdout.write(`${PROG}: could not render the timeline (${msg})\n`);
});
