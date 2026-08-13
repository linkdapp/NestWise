---
title: "NestWise / Road to Oracle OCM — Repo Rebrand & GitHub Metadata"
generated: 2026-08-12
status: "proposal — nothing pushed to GitHub yet, so renaming now is zero-cost"
---

# Repo rebrand & GitHub metadata

Companion to the rebranded root [`README.md`](README.md). This file holds the
GitHub-UI-level fields (repo name, Description, About, Topics) that live outside
`README.md` itself, so they don't get lost between chat and the actual GitHub
settings page. Copy-paste directly into GitHub's repo settings.

**Timing note:** this repo has no remote configured yet (see the git setup from the
last session — local commit only). Renaming costs nothing right now; do it before the
first `git push` rather than after, since a rename after publishing breaks anyone's
existing clone URL/bookmark.

---

## 1. Repo name

Current: `Oracle-DBA-POC`

| Option | Pros | Cons |
|---|---|---|
| **`nestwise-oracle-maa`** (recommended) | Carries both the product name and the searchable Oracle/MAA keywords a hiring manager or GitHub search would use | Slightly long |
| `nestwise` | Clean, memorable, most "product-like" | Loses all Oracle/RAC/DBA search signal — the actual audience searching GitHub for DBA portfolio work won't find it by name alone |
| `road-to-oracle-ocm` | Matches the personal-journey framing exactly | Undersells NestWise as a real, named deliverable rather than a side note |

Recommendation: **`nestwise-oracle-maa`**. Rename via GitHub repo Settings → General
→ Repository name. GitHub auto-redirects the old name for a while, but a local
`git remote set-url origin <new-url>` is still needed after.

---

## 2. Short GitHub repository description

(Repo "Description" field, max ~350 characters)

```
NestWise: a real Oracle APEX + ORDS application running on a hand-built 2-node RAC + Data Guard + GoldenGate MAA lab, upgraded live 12c → 19c → 26ai. Infrastructure and application, built and documented in public — including what broke.
```

---

## 3. GitHub "About" section

**Topics (suggested):**
`oracle` `oracle-database` `rac` `data-guard` `goldengate` `maa` `apex` `ords`
`ansible` `high-availability` `dba` `ocm` `nestwise`

(`mongodb` deliberately left off until Phase 10/NestWise v2 actually exists — the
topics list should describe what's built and in progress, not the full roadmap.)

**About text:**
```
Road to Oracle OCM — building Maximum Availability Architecture by hand, then proving it works with a real application on top.

NestWise is a small Oracle APEX + ORDS app (local recommendations: neighborhoods, restaurants, stays) running on a real 2-node RAC + Data Guard + GoldenGate stack. Everything is scripted, upgradeable, and documented in public — 45+ real build issues and fixes logged along the way.
```

---

## 4. Quick reference (for another AI picking this up later)

**Project name:** NestWise (application) + Road to Oracle OCM (infrastructure lab)

**Core story:** A hand-built Oracle Maximum Availability Architecture lab (2-node RAC
→ Data Guard → GoldenGate, upgraded 12c→19c→26ai) that hosts NestWise, a real Oracle
APEX + ORDS application. NestWise ships pure-Oracle first (Phase 3); a MongoDB-backed
v2 lands later (Phase 10) as its own cross-database integration phase, not bundled
into the initial release.

**Current state (2026-08-12):** Phase 0/1 built — 2-node RAC (GI 19c, DB 12.2.0.1,
ASM) with a running General Purpose non-CDB database (`apexdb`). Phase 2 (Data
Guard) in progress. NestWise v1 is the next phase after that.

**Key technologies:** Oracle RAC, ASM, Data Guard, GoldenGate, OEM; Oracle APEX +
ORDS; MongoDB (later phase); Ansible; Swingbench; AHF.

**Tone:** Confident, specific, evidence-based — real command names, real version
numbers, real failure-and-fix history (`docs/known-risks.md`), not generic "best
practices" language. Audience is dual: a plain-language pitch for non-technical
readers, full technical depth for DBAs and hiring managers who know the space.
