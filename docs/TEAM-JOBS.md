# How a team job runs

When you give the chat a project, Aether (the chat) decides how much process it needs and then runs your
FreeLLMAPI and Ollama agents as a team. This page explains each step, what the agents see, how the work is
checked, and how to get the best results.

## 1. Sizing the request

| Score | Route | What happens |
|---|---|---|
| question | **Answer** | One agent answers. |
| ≤ 24 | **Quick** | One agent builds it. Aether runs its automatic checks (step 5), with up to 2 repair rounds, and the agent writes a summary. |
| 25–50 | **Standard** | Team job (steps 2–6). |
| > 50 | **Deep** | Team job (steps 2–6). |

What raises the score:

- databases, auth, external APIs, infrastructure, security;
- a long brief (over 120 words);
- **a list of requirements:** each numbered or bulleted line beyond three adds 3 points (up to 25), so a written
  spec always gets a team.

"Simple", "small" and similar words only lower the score in short requests (80 words or fewer).

## 2. Plan: the lead writes the contract

Teammates work in parallel and can't talk to each other, so the lead's plan is the contract they all build to.
It must have:

- **Goal**: one line.
- **Requirements**: every requirement in your request as `R1`, `R2`, …
- **Architecture**:
  - the file layout;
  - exact versions and URLs;
  - for every file, what it exports (names, signatures, element ids) and what it uses from which other file;
  - how to start it.
- **Tasks**: `@Name: what to build | files: a.js, b.css`.
  - Every file has exactly one owner.
  - The page markup and the script that drives it belong to the same person.
- **Acceptance checks**: the commands that prove it works.

Guards in this step:

- **Team size:** at most **4 builders**. If the plan uses more, Aether merges the extra tasks into the first
  four. The other agents stay free to take over from anyone who fails, and one becomes the tester.
- **Read-only:** the lead may only look around. It can't write files (free models like to start building alone
  here).
- **Cut-off plans:** if the plan stops before its Tasks, Aether asks the lead for just the Tasks.
- **Plan ends when the Tasks are written:** acceptance-check commands in the plan aren't run then (nothing
  exists yet). They run at verification.
- **Unowned files:** a file the Architecture names but no task owns (often the entry `js/main.js`) is given to a
  teammate: entry points to the page's owner, others to the owner of files in the same folder.
- **Versions and assets:** the lead pins one version of a library and its add-ons. Images and textures are
  planned as drawn in code or as real `.svg`, because no agent can write a binary file.

The plan is saved in the project as `.aether/PLAN.md`.

## 3. Work: each builder writes its own files

Each agent gets the same fixed context however long the job runs:

- your full request;
- the plan;
- **the files it owns**;
- a listing of the project's files with sizes;
- its own thread: its replies and the output of its own commands. Other agents' chatter is left out.

Rules:

- **Ownership:** writing a file someone else owns is refused. If an agent stops responding, its files pass to
  whoever takes over.
- **Unfinished owners:** an agent that stops before writing all its files is sent back to write the missing
  ones.
- **Command output:** comes back with the start of each output kept, so a `cat` of a file shows the file.
- **Repeat reads:** a repeated identical read-only command, with nothing changed since, is not run again.
- **Command limit:** at most 4 commands run per reply, and the agent is told about any it has to resend.
- **Cut-off replies:** a reply that stops at the provider's length limit, or inside an unclosed code block (a
  half-written file), is continued automatically. A continuation that re-opens the block or repeats the last lines
  is cleaned before it's joined on.
- **Broken file blocks:** an ```aether block with bad JSON is repaired where the file is still complete: wrong
  closing brackets, JS escapes like `\'`, quotes left unescaped in HTML. If nothing can be recovered, the agent
  is told exactly why (cut off at N characters, or the JSON error and where) instead of "you did nothing".
- **One server per folder:** `aserve .` reuses the server already serving that folder.
- **Runaway replies:** pages of repetition, or another tool-call syntax, are cut and the agent is asked again.

## 4. Test: a tester writes acceptance tests

For anything with a web page, an agent who didn't build it writes `.aether/e2e.json`. This is at least 8
browser steps covering every requirement a user can see or do: open and close dialogs, create, edit and
delete, validation, search, keyboard shortcuts, persistence after a reload, theme. They use the real ids from
the page:

```json
[{"click": "#new-card-btn"}, {"expect": "#card-modal", "visible": true},
 {"type": ["#card-title", "Buy milk"]}, {"submit": "#card-form"},
 {"expect": ".card", "text": "Buy milk"}, {"reload": true}, {"expect": ".card", "text": "Buy milk"}]
```

The tester is sent back if the file is missing, invalid or too short, and it may not change the app.

## 5. Verify: checks Aether runs itself, then the lead

Before the lead looks at anything, Aether runs these checks itself. A model can't talk its way past them:

| Check | What it catches |
|---|---|
| **Tests** | `npm test`, `node --test <files>`, `python3 -m unittest` / `pytest`, and a Python compile. |
| **Deliverables** | Every file in the plan exists and has no `TODO` / not-implemented parts. |
| **Contract check** (`contract_check.py`) | JS imports naming things the other file doesn't export, imports of missing files, HTML referencing missing files, element ids the scripts look up that the page doesn't have, CSS state classes (`.modal.active`) that no script ever adds, images, sounds or fonts that are empty or fake (SVG text saved as `earth.jpg`), and bare imports the page's importmap can't resolve (a prefix key like `"three/addons"` missing its trailing `/`). It reports all of them at once. |
| **Browser check** (`verify-web`) | Aether serves the page and loads it in headless Chrome. It reports uncaught errors, `console.error` and failed requests, what is on screen, dialogs left open over the page, and an empty page. It clicks every button and reports any errors, then runs the tester's steps. |

Then:

- **The lead** checks the plan's requirements one by one with evidence. If Aether's checks failed, the verdict
  is FAIL, whatever the lead says.
- **Repair rounds:** one **integrator** per round gets the full list of failures and fixes them in any file.
  It's chosen from the owners of the failing files, in rotation. One person at a time, because parallel fixers
  undo each other's changes. It must re-run **all** the checks, not only the one that failed.
- **Rounds:** up to 4 verifications (3 repair rounds).
- **Cleanup:** servers left running by earlier steps are stopped before each round.

## 6. Summary

The lead's hand-over has these sections:

- Result
- **Requirements** (✓ / ✗ / ? per item)
- Where
- How to run
- Who did what
- Open issues

If the final verification failed, the lead is told so and must list the failures.

Aether then adds its own last line, **Final check: PASSED** or **Final check: FAILED — …** with each failing
check, so the outcome is never only a model's claim. A failed job can be continued in the same session ("fix
the failing checks").

## Writing a good request

- List the requirements as numbered lines. They become the checklist the work is tested against.
- Say how it must run (`python3 -m http.server 8000`, `python3 -m unittest`). That becomes an acceptance check.
- Name the technology if you care (framework, language, no build step…).
- For follow-ups ("add dark mode", "fix the failing checks"), stay in the same session. The agent sees the
  earlier conversation and the project's files.

## What to expect from free models

The checks make the outcome honest. They don't make weak models strong.

- On a 12-requirement web app, a team of free models now finds and fixes most integration bugs within its
  repair rounds.
- Some runs still end **Final check: FAILED** with the list of what is left. Before these checks, runs like
  that were reported as finished.
- Results get worse late in the day, when free providers hit their daily quotas.
- Choose the lead and the integrators from your strongest models (Agents tab) where you can.

## Requirements on the machine

- `freeport`, `aserve` and `verify-web` in `~/.local/bin`: `./llm start aether` links them.
- Google Chrome or Chromium, for the browser check. Without it the browser part is skipped.
- `lsof`, for cleaning up stray servers.
