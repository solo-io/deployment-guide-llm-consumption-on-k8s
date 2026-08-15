# Securing, Observing, and Controlling LLM Consumption on Kubernetes

A validated deployment guide for putting **Solo Enterprise for agentgateway** between your
applications and your LLM providers, so that identity, policy, cost and routing are enforced at
the gateway rather than inside every application.

Published solution:
[solo.io/solutions/securing-observing-and-controlling-llm-consumption-on-kubernetes](https://www.solo.io/solutions/securing-observing-and-controlling-llm-consumption-on-kubernetes)

---

## The problem this solves

Direct provider access is the fastest way to ship, so it is what almost everyone does. Keys spread
across teams, repositories and CI pipelines, applications bind to one provider's API, and the gaps
stay tolerable for as long as the workload is a person typing into a box.

Agents end that. A single user action fans out into dozens of model calls, tool calls and retries,
so consumption becomes a function of how a loop terminates rather than of how many people are
working. The questions get harder at the same time. Who sent this prompt. What did this team
spend. Can we stop that job before morning. Can we rotate that key without an outage. Can we move
to a cheaper model without asking twelve teams to ship a change.

Every one of those needs somewhere to stand between your applications and your providers.

---

## What you get

Seventeen steps, run in sequence, each verified on a live cluster:

| Section | What it establishes |
|---|---|
| **Up and Running** | The proxy deployed, a provider backend connected, traffic flowing through a route |
| **Secure** | JWT authentication, group and role authorization, content guardrails, audit logging |
| **Observe** | Token metrics with caller attribution, a model cost catalog, spend by user and team |
| **Control** | Virtual keys, budgets in dollars or tokens, model aliasing, failover, prompt enrichment |
| **Validate** | An end-to-end check that every control is in place and enforcing |

Every command, manifest and output in the guide was captured from a live cluster, not written
from documentation. The product versions this release was validated against are stated at the
top of the guide and in the release notes.

---

## Before you start

| Requirement | Notes |
|---|---|
| A Kubernetes cluster | kind is fine for evaluation; see [`docs/attachments.md`](docs/attachments.md) |
| `kubectl`, `helm`, `jq`, `curl` | Standard tooling |
| A Solo Enterprise licence key | Contact your Solo account team |
| An Anthropic API key | The reference provider. Others are covered in Attachment C |
| An OpenAI API key | For the content moderation guardrail in Step 8.3 only |
| An identity provider | Keycloak setup for a lab is in Attachment A |

---

## Getting started

Read [`docs/deployment-guide-keycloak.md`](docs/deployment-guide-keycloak.md) from the top. It is written to be run
in order, and each step verifies before the next depends on it.

If you do not already have an identity provider to test against, start with **Attachment A** in
[`docs/attachments.md`](docs/attachments.md), which stands up Keycloak with a prepared realm.

### Or build it automatically

The same guide can be executed end to end, then asserted, without working through it by hand.

```bash
cd auto-build && ./preflight.sh && ./up.sh
```

See [`auto-build/README.md`](auto-build/README.md) for credentials, flags and how it works.

---

## Repository layout

```
docs/
  deployment-guide-keycloak.md
                           The guide. Read this first. Keycloak on kind is the
                           reference path it builds; the attachments branch off it.
  attachments.md           Optional branches: IdPs, other providers, observability, guardrails
  images/                  Architecture diagram and dashboard screenshots
infra/
  keycloak/                Realm definition and manifests, used directly by Attachment A
auto-build/
  preflight.sh             Checks tooling, cluster context, credentials and IdP before building
  up.sh                    Builds the environment by running the guide end to end
  verify.sh                Asserts every control is in place and enforcing
  down.sh                  Tears the environment down
  lib/                     Shared by the four above
    extract.sh             Pulls the runnable blocks out of the guide, in document order
    waits.sh               Wait and poll conditions, keyed to the guide's block IDs
    session.sh             Sourced, to put a shell in the state the guide assumes
  .env.example             Your credentials; copy to .env.local
  README.md                How to supply credentials and run it
```

Product versions are not duplicated here. They are pinned in the environment setup block at the
top of the guide, which is itself a runnable block, so the guide and the automation cannot
disagree about what is being deployed.

---

## Versioning

This guide follows [Semantic Versioning](https://semver.org/). The version
describes the guide, not the products it deploys.

| Bump | When |
|---|---|
| **Major** | A significant change to the solution. Recorded in `DECISIONS.md` when it happens. |
| **Minor** | Recertification against a new LTS release of a Solo product in the solution, including any features that arrive with it. Also substantive content changes on an unchanged product surface: swapping the reference third-party service, adding a section or attachment, reworking an existing one. |
| **Patch** | Documentation corrections and automation script fixes. |

Each release lists the product versions it was validated against, and any
notable features added. Use the release notes and the diff between releases
to see what changed.

Scope: this guide documents a validated deployment at a point in time. It
does not cover upgrade paths between product versions, and does not track
product breaking changes. Those belong to the product documentation.

---

## Contributing

Corrections are welcome, particularly from anyone who has run the guide and found that reality
disagrees with it. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for commit conventions and what to
check before opening a pull request.

---

## Support

This repository is reference material accompanying a published solution. It is not a supported
Solo product and carries no SLA.

For the products it deploys, use your normal Solo support channel. For problems with the guide
itself, open an issue here.
