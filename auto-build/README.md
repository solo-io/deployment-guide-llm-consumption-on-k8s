# auto-build

Builds the environment described in [`../docs/deployment-guide.md`](../docs/deployment-guide.md)
by running the guide itself.

Six scripts exist:

| Script | What it does |
|---|---|
| `extract.sh` | Pulls the runnable blocks out of the guide, in document order |
| `waits.sh` | A readiness condition per block ID, plus the lookup |
| `session.sh` | Sourced. Puts your shell in the state the guide assumes |
| `up.sh` | Builds by running the guide, then verifies |
| `verify.sh` | Asserts that the controls are in place and enforcing |
| `down.sh` | Removes what the guide created |

`preflight.sh` is not written yet. There is no `--mock-data`: it was documented before it existed,
and a flag that silently does nothing is worse than one that is missing, so it is gone until the
traffic generator is built.

A build and a verification answer different questions, which is why the exit status separates them.
`up.sh` proves the guide works. `verify.sh` proves the environment does.

---

## Credentials

Three secrets are needed. The guide's environment setup block sets them to placeholders, and your
real values override them.

| Variable | Used for |
|---|---|
| `AGENTGATEWAY_LICENSE_KEY` | Solo Enterprise licence. Contact your Solo account team. |
| `ANTHROPIC_API_KEY` | The reference LLM provider. |
| `OPENAI_API_KEY` | The moderation guardrail in Step 8.3 only. |

Pick one of the two options below. **Do not do both.** `up.sh` enforces this rather than trusting
it: a variable set in both places to different values stops the run and names the variable, because
which one wins would otherwise depend on shell history.

### Option 1 — a local file

Copy the example and fill it in:

```bash
cp .env.example .env.local
$EDITOR .env.local
source .env.local
```

`.env.local` is gitignored. It will never be committed, and it is the only file in this repository
intended to hold live credentials. `up.sh` sources it itself, so the `source` above is only needed
for running guide commands by hand.

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

`OPENAI_API_KEY` is the one you can leave out. `up.sh` warns and continues, and the guardrail block
in 8.3 then installs a moderation guardrail with no credential, which the guide's own note for that
step says returns 503 on every request. Set it, or tag that block `when=manual`.

---

## Usage

```bash
./up.sh                          # build, then verify
./up.sh --no-verify              # build only
./up.sh --dry-run                # print the execution plan, run nothing
./up.sh --from <block-id>        # resume from a block
./up.sh --guide <file>           # run a different guide

./verify.sh                      # assert against an environment that is already up

./down.sh                        # remove what the guide created
./down.sh --dry-run              # say what would go, remove nothing
./down.sh --all                  # also the CRDs, Keycloak and the kind cluster
```

`up.sh` runs `verify.sh` itself when the build succeeds, and its exit status says which half failed:

| Exit | Meaning |
|---|---|
| 0 | built, and verified |
| 2 | would not start: bad arguments, a missing guide, a credential conflict, a block that is not valid shell |
| 3 | built, but a control is not enforcing |
| other | the build failed, with the failing command's own status |

A verification failure leaves the port-forwards up, because that is the state in which you can go and
look at the control that failed. A build failure closes them, so the next run starts clean.

Start with `--dry-run`. It resolves the blocks, the skips, the waits and the credential source, and
checks that every block that would run is valid shell, without touching the cluster.

Both scripts colour their status output, and only when stdout is a terminal and `NO_COLOR` is unset.
Piping to a file or running in CI turns it off, and the glyphs become `[ok]` and `[FAIL]` there: a log
full of coloured circles is harder to read afterwards than words are. The circle is `U+25CF` rather
than an emoji, because emoji are two cells wide in some terminals and one in others, which moves
every column after them.

`--from` re-runs a prelude first: the environment setup block, your credentials, and the blocks that
define the `forwards`, `get_token` and `decode_jwt` helpers, because a block halfway through the
guide expects them to exist. It does not re-run 12.2's traffic generator, which defines
`send_traffic` and then calls it five times against your provider.

---

## What verify.sh asserts

It sources `session.sh`, so the tokens and forwards it needs are there before
anything is asserted, then checks sixteen things against a cluster that is
already up:

| Area | Assertion |
|---|---|
| Authentication | anonymous requests to `/llm`, `/llm-svc`, `/llm-alias` and `/llm-failover` are all 401 |
| Authorization | a `dev` token is 200, an `agent` token is 403 |
| Guardrails | a prompt containing an SSN is 400, and an email in a buffered response comes back as `<EMAIL_ADDRESS>` |
| Virtual keys | the key in `x-api-key` is 200, the same key as a bearer token is 401 |
| Ceilings | `max_tokens: 5000` yields 500 completion tokens and `finish_reason: length` |
| Budgets | `llm-budgets` reports both `Accepted` and `Enforced` |
| Cost catalog | the proxy log says it is watching `count=2` catalog files |
| Aliasing | `acme-chat` on `/llm-alias` resolves to `$LLM_PRIMARY_MODEL` |

Each one prints PASS or FAIL with expected and actual, and the exit status is the
number of failures. Five of them bill your provider, one for 500 output tokens.

Three assertions are deliberately absent, each because making them would fail a
working gateway rather than merely be fragile:

**Masking on a streamed response.** On v2026.7.1 `Mask` does not apply to a
stream, only `Reject` does. An unmasked address in a streamed body is correct
behaviour on this version.

**The model total in the catalog log line.** `models=` moves with the shipped
catalog, without you changing anything. `count=2` is the stable fact.

**Anything using a token fetched at the start of the run.** The reference realm's
lifespan is short, so every token is fetched immediately before the request that
uses it. An expired one turns a 403 assertion into a 401, which reads as an
authorization bug that is not there.

`VERIFY_GW` points it at a different local port, which is also how its failure
path gets exercised without breaking anything.

---

## Tearing it down

`down.sh` removes the port-forwards, the resources the guide created in the namespace, the three Helm
releases, and then the namespace. In that order: the custom resources go while their controller is
still running, because a resource with a finalizer on it outlives the controller that would clear it,
and a namespace deleted first can sit in `Terminating` with nothing left to process it.

It leaves three things alone unless told:

**The CRDs.** Deleting a CRD deletes every resource of that kind in the cluster, including ones this
guide never created. `--crds` removes them. `up.sh` reinstalls them, so leaving them costs a rebuild
nothing.

**The cluster.** `--cluster` deletes the kind cluster named by `KIND_CLUSTER_NAME`, default `kind`.

**Keycloak.** It comes from Attachment A rather than the guide. `--keycloak` removes the container.

It also leaves `agentgateway-values.yaml` and `catalog.json` on disk and says so. Step 1 tells you to
keep the values file for upgrades, and a catalog you generated is worth keeping too.

Running it against a half-built cluster, an already torn down one, or no cluster at all is fine.
Everything is checked for before it is removed, absence is reported rather than treated as an error,
and a second run says the same thing as the first. The exit status counts only things that failed to
go, so nothing to remove is a clean exit rather than an error.

---

## Working through the guide by hand

`session.sh` is sourced, not run, and puts the current shell into the state the
guide assumes:

```bash
. ./session.sh
```

It evaluates the guide's environment setup block and the blocks that define
`forwards`, `get_token` and `decode_jwt`, applies your credentials over the
placeholders the setup block sets, and makes sure the port-forwards are up.
After it, a command copied out of the guide works as written, because the
versions, the helpers and the tokens it refers to are all present.

Per port, it checks before it acts. A forward that is answering is left alone,
because replacing one that works costs whatever was in flight and proves
nothing. A port that is listening and not answering is the case that matters:
that is a forward whose pod was replaced, still holding the local port with
nothing at the far end, so it is killed and a new one started. A free port just
gets one. It says which of the three happened for each of 8081, 15020 and 4000.

If a port is held by something that is not a forward for this namespace, it says
so and leaves it alone rather than guessing.

Sourcing it again is safe and is the fastest way back after a rollout has taken
your forwards down.

`up.sh` sources the same file for the credential and port-forward handling
rather than carrying its own copy, and `verify.sh` should source it plainly:
that leaves it in a session it can assert against, with the same three-state
port logic behind it.

It works when sourced from bash or zsh. Three things differ in zsh and all
three are silent in bash, so they are worth knowing if you edit it: `for v in
$LIST` does not split into words, `status` is read-only, and `path` is tied to
`PATH`.

---

## Usage, the lower level scripts

The other two are useful on their own:

```bash
./extract.sh                     # the blocks as one shell script, on stdout
./extract.sh --dry-run           # list them: number, line, ID, when, line count, first line
./extract.sh --manifest          # the same list, tab separated, for tooling
./extract.sh --dry-run <file>    # any markdown file, not just the guide

./waits.sh --list                # block IDs that have a wait
./waits.sh --table               # those IDs with the condition each one runs
./waits.sh --for <block-id>      # the condition for one ID, or nothing
```

`extract.sh` writes a script and never runs one. Piping it to a shell is not the same as `up.sh`:
the stream contains the `when=manual` blocks too, and no waits.

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

`extract.sh` finds those blocks and writes them out in document order, each preceded by a marker
naming the block, where it came from, and its `when` value:

```text
# >>> backend-anthropic-claude-sonnet-backend (deployment-guide.md:364) when=auto
```

`up.sh` reads that stream and runs the blocks in a single shell session. Exports and helper
functions defined in one block are available to the next, exactly as they are for a reader working
through the guide in one terminal. The marker is what lets it name the block and the guide line in
a failure, and what carries the `when` value, so a block that is held back is visible in the stream
rather than missing from it.

Blocks without a `run` tag are expected output, alternatives, or illustrative snippets, and are
ignored. The tag is invisible in rendered markdown, so it costs the reader nothing.

The guide's environment setup block runs first. Your credentials are applied after it, so versions
and configuration come from the guide while secrets come from you. The placeholders that block sets
are cleared rather than overwritten, so one cannot survive by being mistaken for a value.

Waits and polling live in `waits.sh`, keyed to block IDs. They are deliberately not in the guide —
a reader does not need `kubectl wait` in front of them, and a wait that is missing fails loudly on
the next command rather than passing quietly. `up.sh` looks up each block's ID after the block runs
and runs the condition if there is one. Most blocks have none, and that is not a failure.

Some blocks are runnable by a reader but must not run unattended. Those carry `when=manual` in
their info string and are skipped: diagnostics that only apply after a failure, and alternative
branches where a different block is the one automation should take.

Everything else is in the default path. There is no exclusion list — the guide says which blocks
are conditional, so adding a diagnostic does not require a corresponding edit here.

---

## Before it runs anything

`up.sh` checks that every block it is about to run is valid shell, and refuses to start if one is
not. It reports the block ID and the line in the guide, so the fix goes where readers see it.

The usual cause is an unquoted `<placeholder>` value. Bash reads `<` and `>` as redirections, so
`export ANTHROPIC_API_KEY=<your-anthropic-api-key>` is a syntax error rather than an assignment,
for a reader pasting the block as much as for this script. Quote the placeholder. A block that
needs a value only a person can supply belongs behind `when=manual` instead.

It then closes any port-forward left over against `agentgateway-system` and says how many it
closed. A forward does not die with the pod it targets: a rollout leaves the old one holding the
local port, so the next run cannot bind and fails with `bind: address already in use`, and a
request sent through it goes to a dead endpoint. The pattern is the one the guide's own `forwards`
helper uses, scoped to that namespace, so a forward you have open against anything else is left
alone. `--dry-run` starts nothing and closes nothing.

---

## When a run fails

It stops at the failing command and reports, in this shape:

```text
up.sh: a guide block failed
  block:   <the block ID>
  guide:   docs/deployment-guide.md:<the line its fence is on>
  command: <the command that failed, not the block>
  status:  <that command's exit status>

Resume with: ./up.sh --from <the block ID>
```

A wait that times out is reported separately, because the block itself ran and what did not happen
is the readiness condition. The exit status is the failing command's own, so `command not found`
stays distinguishable from a rejected manifest. Status 2 means it never started: bad arguments, a
missing credential, a credential set in two places, a block that is not valid shell.

A run that fails or is interrupted closes the port-forwards on the way out, so the next run starts
clean. A run that succeeds leaves them up, because that is the state verify.sh will want.

A failure is a finding, not a bug in the script. The usual causes, in order of likelihood:

1. **The product changed.** A field moved, a CRD was renamed, a default flipped. Fix the guide,
   not the script — the script runs whatever the guide says.
2. **A block returns non-zero and that is fine.** A `grep` that matches nothing, a `pkill` with
   nothing to kill. Blocks run under `set -e`, so the run stops. The fix is in the guide, where a
   reader is equally entitled to know the command can fail harmlessly.
3. **A wait is missing or too short.** The command ran before its dependency was ready. Add or
   extend the condition in `waits.sh`.
4. **A block ID changed.** A renamed manifest leaves `waits.sh` keyed to an ID that no longer
   exists, and that wait then silently never runs. `up.sh` does not check this yet. Until it does,
   `comm -13 <(./extract.sh --manifest | cut -f1 | sort) <(./waits.sh --list | sort)` prints any
   wait keyed to a block that is not in the guide.

Correcting the guide is the point. The environment is rebuilt from the corrected guide on the next
run, and the fix lands where readers see it.
