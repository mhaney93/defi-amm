# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Trail of Bits security plugins are enabled for this project only, pinned to one commit in `.claude/settings.json`: `building-secure-contracts` (Solidity vulnerability scanners, audit-prep and token-integration checklists), `property-based-testing` (invariant/fuzz test design, Echidna/Medusa), and `dimensional-analysis` (unit and decimal-scaling bugs). Use them for security review and fuzzing work. Each user installs them once after trusting the folder (`/plugin`); to bump the pin, review the upstream diff and update every `sha`.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
