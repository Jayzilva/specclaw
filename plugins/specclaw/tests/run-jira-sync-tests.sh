#!/usr/bin/env bash
# run-jira-sync-tests.sh — regression suite for the two ways bin/specclaw-jira-issue
# failed to keep a Jira card in step with a specclaw change.
#
# The defects:
#
#   D1: the board never moved. `cmd_close` held the only POST to
#       issue/<key>/transitions in the file, and it ran at /specclaw:archive.
#       plan, build and verify only ever rewrote the description or added a
#       comment, so the card sat in the leftmost column for the whole lifecycle
#       and then jumped straight to Done. Fixed by `transition <phase>`, which
#       discovers the project's own transition names rather than assuming them.
#
#   D2: the description was one paragraph. build_adf_doc wrapped the entire
#       proposal + spec + task checklist in a single ADF text node, so every
#       heading, bullet and `- [ ]` checkbox arrived in Jira as literal
#       characters in one wall of text. Fixed by adf_render_markdown, which
#       emits real heading/bulletList/taskList/codeBlock/rule nodes.
#
# The pure logic — markdown -> ADF, and candidate -> transition id — is tested
# directly; nothing here talks to Jira.
#
# Plain bash + coreutils + node. Run from anywhere:
#   bash plugins/specclaw/tests/run-jira-sync-tests.sh
# Exits non-zero if any case fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/../bin" && pwd)"
JIRA="$BIN_DIR/specclaw-jira-issue"

[[ -f "$JIRA" ]] || { echo "FATAL: missing file: $JIRA" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH" >&2; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label (= '$actual')"
  else
    fail "$label — expected '$expected', got '$actual'"
  fi
}

# The script exits on its auth checks before any function is reachable, so lift
# the units under test out of it rather than sourcing the whole thing. Both
# blocks are delimited by their own section banners.
extract() {
  awk -v start="$1" -v end="$2" '
    index($0, start) { on = 1 }
    on && index($0, end) { exit }
    on { print }
  ' "$JIRA"
}

LIB="$WORK/lib.sh"
{
  extract "# ─── Markdown → ADF ─" "# ─── Board transitions ─"
  extract "# ─── Board transitions ─" "# ─── Subcommands ─"
} > "$LIB"

# The transition helpers call jiraapi_get/die, which the extract leaves behind.
# Only resolve_transition and transition_candidates are exercised here.
# shellcheck disable=SC1090
source "$LIB" || { echo "FATAL: could not source extracted units" >&2; exit 2; }

# ── D2: markdown → ADF ───────────────────────────────────────────────────────

# What a change directory actually feeds the description: proposal headings and
# prose, a spec with a fenced block and a rule, and the live task checklist
# build_task_checklist appends.
cat > "$WORK/body.md" <<'EOF'
# Add rate limiting

The **gateway** accepts unbounded requests, so one client can starve the rest.
See [the incident](https://example.test/inc/42).

## Scope

- Token bucket per API key
- A `429` response with Retry-After

---

```python
limit = 100
```

> Out of scope: per-user quotas.

--- Tasks (1/2 complete) ---

- [x] `T1` — Add the bucket
- [ ] `T2` — Wire the middleware
EOF

ADF="$(build_adf_description "$(cat "$WORK/body.md")")"

# The whole point of the fix: not one paragraph carrying everything.
node_q() { printf '%s' "$ADF" | node -e "
const d = JSON.parse(require('fs').readFileSync(0, 'utf8'));
$1
"; }

assert_eq "doc is valid JSON of type doc" "doc" "$(node_q "process.stdout.write(d.type)")"

assert_eq "renders more than one block" "true" \
  "$(node_q "process.stdout.write(String(d.content.length > 1))")"

assert_eq "no block is a single everything-paragraph" "false" \
  "$(node_q "process.stdout.write(String(d.content.length === 1 && d.content[0].type === 'paragraph'))")"

types="$(node_q "process.stdout.write([...new Set(d.content.map(n => n.type))].sort().join(','))")"
for want in heading bulletList taskList codeBlock rule blockquote paragraph; do
  case ",$types," in
    *",$want,"*) pass "emits a $want node" ;;
    *)           fail "missing a $want node (got: $types)" ;;
  esac
done

assert_eq "h1 keeps its level" "1" \
  "$(node_q "process.stdout.write(String(d.content.find(n => n.type === 'heading').attrs.level))")"

assert_eq "h2 keeps its level" "2" \
  "$(node_q "process.stdout.write(String(d.content.filter(n => n.type === 'heading')[1].attrs.level))")"

# A checked box must arrive as a DONE taskItem, not the characters '[x]'.
assert_eq "task states track the checkbox" "DONE,TODO" \
  "$(node_q "
const tl = d.content.find(n => n.type === 'taskList');
process.stdout.write(tl.content.map(t => t.attrs.state).join(','));
")"

assert_eq "taskItem text drops the checkbox syntax" "true" \
  "$(node_q "
const tl = d.content.find(n => n.type === 'taskList');
const txt = JSON.stringify(tl.content);
process.stdout.write(String(!txt.includes('[x]') && !txt.includes('[ ]')));
")"

assert_eq "taskList localIds are unique" "true" \
  "$(node_q "
const ids = d.content.filter(n => n.type === 'taskList').flatMap(l => l.content.map(t => t.attrs.localId));
process.stdout.write(String(ids.length === new Set(ids).size));
")"

assert_eq "bullet list has both items" "2" \
  "$(node_q "process.stdout.write(String(d.content.find(n => n.type === 'bulletList').content.length))")"

assert_eq "fenced block keeps its language" "python" \
  "$(node_q "process.stdout.write(d.content.find(n => n.type === 'codeBlock').attrs.language)")"

assert_eq "fenced block keeps its body" "limit = 100" \
  "$(node_q "process.stdout.write(d.content.find(n => n.type === 'codeBlock').content[0].text)")"

assert_eq "bold becomes a strong mark" "true" \
  "$(node_q "process.stdout.write(String(JSON.stringify(d).includes('\"type\":\"strong\"')))")"

assert_eq "backticks become a code mark" "true" \
  "$(node_q "process.stdout.write(String(JSON.stringify(d).includes('\"type\":\"code\"')))")"

assert_eq "markdown link becomes a link mark" "https://example.test/inc/42" \
  "$(node_q "
const walk = n => n.marks && n.marks.find(m => m.type === 'link')
  ? n.marks.find(m => m.type === 'link').attrs.href
  : (n.content || []).map(walk).find(Boolean);
process.stdout.write(walk(d) || '');
")"

# ADF forbids an empty text node; anything that renders to nothing must not
# produce one.
assert_eq "no empty text nodes" "true" \
  "$(node_q "
const walk = n => (n.type === 'text' && n.text === '' ? false
  : (n.content || []).every(walk));
process.stdout.write(String(walk(d)));
")"

# CRLF is the normal case on Windows and must not survive into the ADF.
CRLF_ADF="$(printf '# Title\r\n\r\n- one\r\n- two\r\n' | adf_render_markdown)"
assert_eq "CRLF input leaves no carriage returns" "true" \
  "$(printf '%s' "$CRLF_ADF" | node -e "
process.stdout.write(String(!require('fs').readFileSync(0, 'utf8').includes('\\\\r')));
")"
assert_eq "CRLF input still yields heading + list" "heading,bulletList" \
  "$(printf '%s' "$CRLF_ADF" | node -e "
const d = JSON.parse(require('fs').readFileSync(0, 'utf8'));
process.stdout.write(d.content.map(n => n.type).join(','));
")"

# Jira rejects an over-long description outright, so the source is trimmed.
BIG="$(node -e "process.stdout.write('word '.repeat(20000))")"
BIG_ADF="$(printf '%s' "$BIG" | adf_render_markdown)"
assert_eq "over-long source is truncated under the cap" "true" \
  "$(printf '%s' "$BIG_ADF" | node -e "
const d = JSON.parse(require('fs').readFileSync(0, 'utf8'));
process.stdout.write(String(JSON.stringify(d).length < 32767));
")"
assert_eq "truncation says so" "true" \
  "$(printf '%s' "$BIG_ADF" | node -e "
process.stdout.write(String(require('fs').readFileSync(0, 'utf8').includes('Truncated by specclaw')));
")"

# An empty body must still be a legal document.
assert_eq "empty input is still a valid doc" "1" \
  "$(printf '' | adf_render_markdown | node -e "
const d = JSON.parse(require('fs').readFileSync(0, 'utf8'));
process.stdout.write(String(d.content.length));
")"

# ── D1: phase → transition ───────────────────────────────────────────────────

# A Jira transitions payload in its real shape: the action name and the status
# it lands on differ, which is exactly what the old grep conflated.
TRANSITIONS='{"expand":"transitions","transitions":[
  {"id":"11","name":"Start Progress","to":{"name":"In Progress","id":"3"}},
  {"id":"21","name":"Ready for Review","to":{"name":"In Review","id":"4"}},
  {"id":"31","name":"Resolve Issue","to":{"name":"Done","id":"5"}}
]}'

resolve_for() {
  local phase="$1" cands=()
  while IFS= read -r c; do cands+=("$c"); done < <(transition_candidates "$phase")
  printf '%s' "$TRANSITIONS" | resolve_transition "${cands[@]}" || true
}

assert_eq "build resolves via the target status name" "$(printf '11\tIn Progress')" "$(resolve_for build)"
assert_eq "verify resolves via the target status name" "$(printf '21\tIn Review')" "$(resolve_for verify)"
assert_eq "done resolves via the target status name" "$(printf '31\tDone')" "$(resolve_for done)"
assert_eq "plan finds nothing in this workflow" "" "$(resolve_for plan)"

# Matching on the action name alone, when the target is named something else.
ACTION_ONLY='{"transitions":[{"id":"77","name":"In Progress","to":{"name":"Bucket B","id":"9"}}]}'
assert_eq "matches the action name when the status differs" "$(printf '77\tBucket B')" \
  "$(printf '%s' "$ACTION_ONLY" | resolve_transition "In Progress" "Doing")"

# Candidate order decides, not the order Jira happens to return.
BOTH='{"transitions":[
  {"id":"90","name":"Doing","to":{"name":"Doing","id":"1"}},
  {"id":"91","name":"In Progress","to":{"name":"In Progress","id":"2"}}
]}'
assert_eq "first candidate wins over Jira ordering" "$(printf '91\tIn Progress')" \
  "$(printf '%s' "$BOTH" | resolve_transition "In Progress" "Doing")"

assert_eq "matching is case-insensitive" "$(printf '11\tIn Progress')" \
  "$(printf '%s' "$TRANSITIONS" | resolve_transition "IN PROGRESS")"

assert_eq "an empty workflow resolves nothing" "" \
  "$(printf '{"transitions":[]}' | resolve_transition "Done" || true)"

assert_eq "malformed JSON resolves nothing rather than crashing" "" \
  "$(printf 'not json' | resolve_transition "Done" || true)"

assert_eq "every phase declares candidates" "plan build verify done" \
  "$(for p in plan build verify done; do
       transition_candidates "$p" >/dev/null 2>&1 && printf '%s ' "$p"
     done | sed 's/ $//')"

assert_eq "an unknown phase declares none" "1" \
  "$(transition_candidates bogus >/dev/null 2>&1; echo $?)"

# ── Summary ──────────────────────────────────────────────────────────────────

echo
echo "─────────────────────────────"
echo "PASS: $PASS   FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
