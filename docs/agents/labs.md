# Labs

How to build, validate, and close out a Forge lab. Jimmie types every command in a lab himself; you scaffold the lab, the scripts behind it, and the review.

## Where things live

- `docs/labs/phase-N-*.html`: one interactive lab per phase, served by GitHub Pages and locally with `python3 -m http.server` (ADR-0008).
- `docs/labs/assets/TEMPLATE.html`: the markup contract. Its top comment lists the rules; rules 11 to 17 cover the learning features from ADR-0009.
- `docs/labs/assets/lab.js` and `lab.css`: shared behavior and styles. Progress, quiz scores, and teach-back answers live in the reader's browser under `forge-labs/<lab id>/`.
- `docs/labs/index.html`: the dashboard. Add a lab's `href` to its `labs` array when the lab ships.
- `scripts/drills/phase-N.sh`: the fault-injection drill for a phase, built on `scripts/drills/lib.sh`.
- `scripts/lab-journal.sh`: the command journal. Sourced, never executed. Writes `.journal/<phase>.log`, which is gitignored.

## Build a lab

1. Start from the ticket's acceptance criteria and the vocabulary in `CONTEXT.md`. A criterion that says "Jimmie can explain X" becomes the first teach-back prompt.
2. Write the drill script before the drill step. Inject each fault in a scratch cluster and record the real symptoms, then write the hints from those symptoms. Hints describe symptoms and never name the fault.
3. Build the page per every rule in the template comment. Map each new concept to its ECS or Cloud Run equivalent.
4. Apply the fade schedule below to decide which steps hide their commands.
5. Write prose with the `technical-writing` skill and finish with the `unslop` skill. No em dashes.
6. Validate with the two agents described next. Fix findings, commit, push, and add the lab to the dashboard.

## Fade schedule

| Phases | Steps with hidden commands | What the hint holds |
|---|---|---|
| 0 to 2 | One per lab | The commands |
| 3 and 4 | Two per lab | The commands |
| 5 onward | Every step that repeats an earlier concept | A link to the earlier lab's step |

## Drill script conventions

Each script sets `PHASE` and `FAULTS`, defines `preflight`, `do_break`, `do_check`, and `do_undo`, sources `lib.sh`, and calls `main "$@"`.

- `FORGE_CONTEXT` selects the cluster (default `kind-dc-east`). `FORGE_HTTP_PORT` selects the ingress port (default 8080). `FORGE_DRILL_FAULT` forces one named fault; validation uses it to cover every fault.
- `break` refuses to run while a fault is active. Its output never names the fault.
- `check` verifies two things: the drifted object matches the file in `deploy/tenants/acme/` again, and the reader-visible symptom is gone. Its FAIL messages stay at the symptom level. PASS names the fault and clears the state file in `.scratch/drills/`.
- `undo` names the fault and repairs it, for readers who give up.
- Faults change one field of one object, or one machine, so the reader can find them with the commands the lab already taught.

## Validate a lab

Run two agents and act on both reports before the lab reaches Jimmie.

The executor runs every command in the lab, the solo step's hidden commands, and every drill fault through break, check, fix, check, and undo, in a throwaway kind cluster named `forge-labcheck` with host ports 7080 and 7443. It sets `FORGE_CONTEXT=kind-forge-labcheck` and `FORGE_HTTP_PORT=7080`. It never touches `kind-dc-east` or `kind-dc-west`, and it deletes `forge-labcheck` when finished. Ask it to quote exact outputs, status codes, and event messages, and to list every place reality differs from the lab text.

The reviewer reads only. It checks the template contract, the drill hints against the drill scripts, vocabulary against `CONTEXT.md`, claims against the ADRs and the ticket, the ECS and Cloud Run mappings, the teach-back model answers, the prose rules, and that every source link resolves.

## Close out a phase

When Jimmie reports a phase done:

1. Verify the acceptance criteria read-only: `kubectl get` with an explicit `--context`, and `curl` against the tenant hostname. Do not mutate his clusters.
2. Review the teach-back export he pastes. Compare each answer with the model answer and the lab body. Reply with one or two sentences per prompt: what was right, what was missing.
3. Read `.journal/phase-N.log`. Look for non-zero exit codes, repeated commands, and commands the lab never gave. Each one is either a lab fix or a note for the next lab.
4. Close the ticket with a comment that records what you verified, the teach-back review, and what the journal showed.
5. Cut the next lab when its ticket starts.

## Skills involved

Design decisions go through `grilling` or `grill-with-docs` and land as ADRs. Prose goes through `technical-writing` and `unslop`. Validation uses general-purpose agents in the two roles above.
