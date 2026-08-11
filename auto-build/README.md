# auto-build

Builds the environment described in [`../docs/deployment-guide.md`](../docs/deployment-guide.md)
by running the guide itself, then asserts that every control is in place and enforcing.

---

## Credentials

Three secrets are needed. The guide's environment setup block sets them to placeholders, and your
real values override them.

| Variable | Used for |
|---|---|
| `AGENTGATEWAY_LICENSE_KEY` | Solo Enterprise licence. Contact your Solo account team. |
| `ANTHROPIC_API_KEY` | The reference LLM provider. |
| `OPENAI_API_KEY` | The moderation guardrail in Step 8.3 only. |

Pick one of the two options below. **Do not do both** — a stale value in a file will quietly win
over the one you exported, or the other way round, depending on shell history.

### Option 1 — a local file

Copy the example and fill it in:

```bash
cp .env.example .env.local
$EDITOR .env.local
source .env.local
```

`.env.local` is gitignored. It will never be committed, and it is the only file in this repository
intended to hold live credentials.

### Option 2 — export directly

If you would rather keep secrets out of files entirely, export them in your shell and leave
`.env.local` absent:

```bash
export AGENTGATEWAY_LICENSE_KEY='...'
export ANTHROPIC_API_KEY='...'
export OPENAI_API_KEY='...'
```

Preferable on a shared or demo machine, where a file outlives the session and an exported variable
does not.

---

## Usage

```bash
./preflight.sh          # tooling, cluster context, credentials, IdP reachability
./up.sh                 # build, then verify
./up.sh --no-verify     # build only
./up.sh --mock-data     # build, verify, then generate traffic to populate the dashboards
./verify.sh             # assert against an environment that is already up
./down.sh               # tear down
```

`preflight.sh` runs first and on its own. It fails before anything is created rather than halfway
through, which is the difference between a five second correction and a teardown.

`verify.sh` is standalone. Point it at any cluster built from this guide, including one you built
by hand, and it will tell you which controls are enforcing.

`--mock-data` sends real requests to your provider and therefore spends real money. It is bounded,
and the amount is reported when it finishes.

---

## How it works

Runnable commands in the guide carry a `run` tag and a stable ID in their fence info string:

````markdown
```bash run id=backend-anthropic-claude-sonnet-backend
kubectl apply -f- <<EOF
...
EOF
```
````

`up.sh` extracts those blocks in document order and executes them in a single shell session.
Exports and helper functions defined in one block are available to the next, exactly as they are
for a reader working through the guide in one terminal.

Blocks without a `run` tag are expected output, alternatives, or illustrative snippets, and are
ignored. The tag is invisible in rendered markdown, so it costs the reader nothing.

The guide's environment setup block runs first. Your credentials are applied after it, so versions
and configuration come from the guide while secrets come from you.

Waits and polling live in `waits.sh`, keyed to block IDs. They are deliberately not in the guide —
a reader does not need `kubectl wait` in front of them, and a wait that is missing fails loudly on
the next command rather than passing quietly.

Some blocks in the guide are runnable by a reader but must not run unattended: the deliberate
ConfigMap break in 14.3, the mispriced catalog in 11.4, the dual-authentication policy in 13.3
that makes a route unusable. These are excluded by ID.

---

## When a run fails

A failure is a finding, not a bug in the script. The usual causes, in order of likelihood:

1. **The product changed.** A field moved, a CRD was renamed, a default flipped. Fix the guide,
   not the script — the script runs whatever the guide says.
2. **A wait is missing or too short.** The command ran before its dependency was ready. Add or
   extend the condition in `waits.sh`.
3. **A block ID changed.** If a manifest was renamed, `waits.sh` may reference an ID that no
   longer exists. The runner reports this at startup rather than silently skipping.

Correcting the guide is the point. The environment is rebuilt from the corrected guide on the next
run, and the fix lands where readers see it.
