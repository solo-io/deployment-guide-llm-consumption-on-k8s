# CLAUDE.md

Read `CONTRIBUTING.md` before changing anything — it covers commit
conventions, style, and what to verify.

Read `auto-build/README.md` before touching the scripts — it defines the
execution contract.

Two rules that override instinct:
- A failing command is a guide problem. Fix `docs/`, not `auto-build/`.
- Never edit generated output. Change the source and regenerate.