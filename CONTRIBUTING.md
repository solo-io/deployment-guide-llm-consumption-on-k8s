# Contributing

Corrections and improvements are welcome, particularly from anyone who has run the guide and
found that reality disagrees with it.

---

## What belongs here

| Change | Where it goes |
|---|---|
| A command, manifest or output that is wrong | `docs/deployment-guide.md` |
| An alternative provider, IdP or observability stack | `docs/attachments.md` |
| A wait that is missing or too short | `auto-build/waits.sh` |
| An assertion that should be checked | `auto-build/verify.sh` |

**Fix the guide, not the automation.** The scripts execute the commands the guide documents, so a
command that fails is a guide problem. Correcting it there means the fix reaches readers as well
as the build.

---

## Before you open a pull request

Run the guide, or the part of it you changed, against a real cluster. A change that has not been
run is a suggestion rather than a correction, and saying so in the pull request is fine — it just
needs to be said.

State which product version you ran against. A command that works on one release and not another
is useful information, and it is invisible unless you mention it.

---

## Commit messages

This repository uses [Conventional Commits](https://www.conventionalcommits.org/). The prefix
determines how the change is released, so it is worth getting right.

```
<type>: <short imperative summary>

<why the change is needed, if it is not obvious from the summary>
```

| Type | Use for | Release effect |
|---|---|---|
| `fix` | A wrong command, manifest, output or explanation | Patch |
| `feat` | New steps or capabilities, usually from a product release | Minor |
| `docs` | Wording, structure or formatting, with no change to what is run | Patch |
| `chore` | Repository housekeeping, tooling, CI | None |
| `refactor` | Restructuring that does not change behaviour | None |

Examples:

```
fix: correct the secret key for provider credentials

The backend expects the key to be Authorization, not apiKey. With the wrong
key the backend reports Accepted=False with a translation error that does not
name the key.
```

```
feat: add response-side guardrails for streamed responses
```

```
docs: clarify that policy status can be Valid while a guard is dropped
```

A breaking change — one that requires a reader to alter an existing deployment — takes a `!` after
the type and a `BREAKING CHANGE:` footer:

```
feat!: move API key authentication to the x-api-key header

BREAKING CHANGE: existing callers sending keys as a bearer token will receive
401 until they move to the new header.
```

---

## Pull request checklist

- [ ] Ran the affected steps against a live cluster
- [ ] Stated the product version it was run against
- [ ] Updated the guide, not only the automation
- [ ] Commit messages follow the convention above
- [ ] Captured output in the guide matches what the cluster actually returned

---

## Style

The guide is written to be run, not skimmed. A few conventions hold it together:

**Verified output only.** Every output block in the guide was captured from a live cluster. If you
add one, paste what you saw rather than what you expected. If a claim has not been verified, say
so rather than implying it has.

**No filler.** Sentences that announce a point rather than making it — "it is worth understanding
that", "this is the part where" — get cut in review. State the fact.

**Callouts are for behaviour that costs time.** Use `> [!WARNING]` for something that will bite,
`> [!NOTE]` for context that helps. Both should be rare enough to still carry weight.

**Runnable commands need a `run` tag** and a stable ID, so automation can execute them:

````markdown
```bash run id=backend-anthropic-claude-sonnet-backend
````

Derive the ID from what the block creates rather than from its step number, so it survives
renumbering. Output blocks, alternatives and illustrative snippets are left untagged.

---

## Reporting a problem without fixing it

Open an issue. Include the command you ran, what you expected, what you got, and the product
version. That is enough to reproduce, and reproducing is most of the work.
