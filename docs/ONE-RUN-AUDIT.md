# One-Run Completion Audit

Empirical audit of whether ONE RUN completes the job today. Read against
committed source at `bb73addb` (branch `main`). No files were changed; this
document is the only artifact.

The demand under audit: a user hands over a PR, an issue, or a spec, and the
run completes all development, testing, and release work and hands back
completion proof, with least cost and highest task value per dollar, without
back-and-forth or failing loops.

Verdict: a default run does reach working code, a session branch, quality
gates, and an Evidence Receipt without human input. It breaks the one-run
promise in five specific places, ranked below. Two of the five are hard stops
that wait on a person. Two are missing measurements, not defects. One is the
last mile of the deliverable.

## Method notes

Every zero reported here carries a positive control, because an unproven zero
is an absent measurement rather than a finding. Controls are printed inline
with each finding. Claims are read against committed source, and each cited
function was read in full before it was judged.

Two mid-audit hypotheses were refuted by the source and are recorded in
"Refuted during this audit" so they are not re-raised.

## 1. A blocked gate escalates to a PAUSE that waits forever, with no timeout and no tty guard

Highest user pain. This is the failing loop the demand names, and in
background mode nobody is watching it.

The escalation ladder defaults are `GATE_CLEAR_LIMIT=3`,
`GATE_ESCALATE_LIMIT=5`, `GATE_PAUSE_LIMIT=10` (`autonomy/run.sh:1513-1515`).
`gate_failure_disposition` (`autonomy/run.sh:11293-11302`) returns `pause`
once a gate's consecutive-failure count reaches 10.

For code review, that disposition does this (`autonomy/run.sh:24473-24477`):

```
log_error "Gate escalation: code_review failed $cr_count times (>= $GATE_PAUSE_LIMIT) - forcing PAUSE for human intervention"
echo "PAUSE" > "${TARGET_DIR:-.}/.loki/signals/GATE_ESCALATION"
touch "${TARGET_DIR:-.}/.loki/PAUSE"
```

`check_human_intervention` (`autonomy/run.sh:25460`) sees that file and calls
`handle_pause` (`autonomy/run.sh:25690`). The wait loop
(`autonomy/run.sh:25793-25818`) is:

```
while [ "$PAUSED" = "true" ]; do
    if [ -f "$loki_dir/STOP" ]; then ... return 1; fi
    if [ ! -f "$loki_dir/PAUSE" ]; then PAUSED=false; break; fi
    if read -t 1 -n 1 2>/dev/null; then rm -f "$loki_dir/PAUSE"; PAUSED=false; break; fi
    sleep 1
done
```

There is no timeout and no maximum wait. The loop exits only on a person
removing `.loki/PAUSE`, creating `.loki/STOP`, or pressing a key. With no TTY
attached (`--bg`, a container, a CI job) the `read` can never fire, so the run
spins on `sleep 1` indefinitely.

There is no non-interactive guard on this path. Positive control: `grep -c
"-t 0" autonomy/run.sh` returns `1`, so the grep does find tty checks in this
file; the single hit is `autonomy/run.sh:22411`, inside the unrelated
spec-contradiction fast-fail. `handle_pause` has none.

Scope it honestly: perpetual mode auto-clears PAUSE and continues
(`autonomy/run.sh:25470-25500`), except when the pause came from budget
enforcement. Default mode does not auto-clear.

## 2. Three gates can terminate the run at exit 20, and that path never opens a PR

`_loki_gate_stuck` (`autonomy/run.sh:11098`, threshold
`LOKI_GATE_STUCK_THRESHOLD:-3`) compares a stable cause line across
consecutive failures. When the same gate fails for the same reason three
times, the run stops rather than grinding. It fires for three gates:

- static analysis, `autonomy/run.sh:24094-24101`
- mock integrity, `autonomy/run.sh:24220-24227`
- mutation integrity, `autonomy/run.sh:24266-24275`

Each does `save_state ... 20` and `return 20` out of `run_autonomous`.

Stopping a non-converging loop is correct behavior and better than grinding.
The one-run break is what the user is left holding: `on_run_complete`, the
function that opens the PR, is called only from the success exits
(`autonomy/run.sh:24803`, `:25025`, `:25661`). A `return 20` leaves
`run_autonomous` before reaching any of them, so no PR is opened. The
deliverable stays on the session branch and the user must discover and finish
it by hand.

This mirrors a deliberate decision elsewhere: the council force-stop path at
`autonomy/run.sh:24770` carries the comment "No on_run_complete: a force-stop
must never open a 'done' PR." The gate-stuck path inherits that outcome
without stating it.

## 3. There is no cost-per-completed-task anywhere; only cost per iteration

This is a missing measurement, reported plainly rather than invented.

The per-iteration writer is `autonomy/run.sh:8303-8318`, emitting
`.loki/metrics/efficiency/iteration-N.json` with `cost_usd` at
`autonomy/run.sh:8315`.

The only aggregation that divides cost by anything is
`autonomy/loki:6447`:

```
'avg_cost_per_iteration': round(total_cost / iteration_count, 2) if iteration_count > 0 else 0,
```

plus the same division at `autonomy/loki:6518`. Both denominators are
iterations, not completed tasks.

The sharpest evidence that the metric was never built: in one script,
`total_cost` is computed at `autonomy/loki:28461` and `tasks_completed` is
emitted at `autonomy/loki:28514` and printed at `autonomy/loki:28557`, about
fifty lines apart, with no division between them. Both numbers are in hand at
the same moment and are never combined.

Searched two ways. Positive control first: `grep -c "cost_usd" autonomy/loki`
returns `19`, so the file and the pattern style both resolve.

- Division by any completed or task count, across `autonomy/loki`,
  `autonomy/run.sh`, `dashboard/*.py`: only the two
  `total_cost / iteration_count` hits above.
- Identifier search for `per_task`, `per-task`, `cost_per`, `per_completed`
  across `autonomy/`, `dashboard/*.py`, `loki-ts/src/`: only
  `avg_cost_per_iteration` at `autonomy/loki:6447`.

An iteration is not a unit of delivered value. A run that solves the task in
two iterations and one that thrashes for twenty both report a healthy average
cost per iteration.

## 4. There is no task-value-per-dollar metric

Zero hits, with a positive control, searched two ways.

Positive control: `grep -rln "cost_usd" autonomy/` resolves to
`autonomy/loki`, `autonomy/run.sh`, `autonomy/context-tracker.py`, so the
recursive search reaches these trees.

- Case-insensitive `value.per.dollar`, `value_per_dollar`, `valuePerDollar`
  across `autonomy/`, `dashboard/`, `memory/`, `loki-ts/src/`: 0 hits.
- Identifier search for `task_value`, `value_score`, `roi` across
  `autonomy/`, `dashboard/`: no metric definition. Hits were unrelated
  substrings (a template line in `autonomy/quickstart.sh:136`, bundled
  `mermaid.min.js`).

Nothing computes value per dollar, and nothing defines task value as a
quantity. The closest artifact is the productivity report at
`autonomy/loki:28535-28545`, which estimates "time saved" as
`total_iterations x 15 minutes`. That is a fixed multiplier applied to
iteration count, not a measure of delivered value, and it rises with a run
that iterates more.

## 5. On the headline issue use case, the PR rests entirely on one default-on guard chain, and the teardown then tells the user to open a PR that already exists

The back-and-forth is not conversational. The agent almost never stops to ask
a question mid-run.

Searched for blocking interactive prompts two ways. Only two exist in the CLI,
both in `cmd_config_init` (`autonomy/loki:12652`): `read -p "Choice [1]: "` at
`autonomy/loki:12669`, and `autonomy/loki:12719`, which already auto-confirms
under `LOKI_AUTO_CONFIRM`, `CI`, or a non-TTY stdin. Neither is on the
`loki start` build path. The `LOKI_PROMPT_INJECTION` handling in
`check_human_intervention` is default-off and consumes input rather than
requesting it (`autonomy/run.sh:25557-25565`).

The real issue is on the founder's named use case, `loki start
owner/repo#123`. With no flags, `create_pr` and `use_worktree` both stay false:
they are set only by `--pr`, `--ship`, `--prepare-pr`, `--worktree`, or
`--detach` (`autonomy/loki:2602`, `:2616`, `:10330`, `:10383`). So the issue
path's own PR block at `autonomy/loki:10762` (`if $create_pr;`) never executes
on a bare no-flag run.

The PR therefore rests entirely on one other path: `on_run_complete`
(`autonomy/run.sh:5246`), which is default ON (`LOKI_DELEGATE_PR:-1`,
`autonomy/run.sh:5259`) and is called from the success exits
(`autonomy/run.sh:24803`, `:25025`, `:25661`). Its guard chain does hold on a
normal run: `GITHUB_PR:-false` does not trigger the early return at
`autonomy/run.sh:5263`; branch protection is on by default
(`autonomy/run.sh:8922`) and `setup_agent_branch` is called unconditionally in
`main()` (`autonomy/run.sh:26681`) before `run_autonomous` at
`autonomy/run.sh:26783`, minting `loki/session-<ts>-<pid>`
(`autonomy/run.sh:8984-8999`), so the non-default-branch guard at
`autonomy/run.sh:5296-5298` passes.

But every remaining link is a silent no-op. Missing `gh`
(`autonomy/run.sh:5279`), failing `gh auth status` (`autonomy/run.sh:5282`),
or a non-GitHub remote (`autonomy/run.sh:5287-5290`) each `return 0` with no
log line at all. On the headline use case the deliverable is the PR, and three
environment conditions can remove it without saying so.

Then the teardown contradicts itself. `create_session_pr` runs later, from
`main()` at `autonomy/run.sh:26956`, after the in-loop `on_run_complete` has
already opened the PR. It reaches `autonomy/run.sh:9175`:

```
if [ "${LOKI_AUTO_PR:-0}" != "1" ]; then
    print_pr_advice "$base" "$branch_name"
    ...
    return 0
fi
```

`print_pr_advice` (`autonomy/lib/git-pr-advisory.sh:69-111`) takes only base,
head, and dir. It consults nothing about an existing PR and unconditionally
prints "To open a pull request: git push -u origin ...". Note that
`_loki_persist_pr_url` writes the opened PR url to `.loki/state/pr-url.txt`
(`autonomy/run.sh:5242`), and repo-wide the only other references are in
`tests/test-issue-to-pr-action.sh`: nothing in the advice path reads it.

So a successful run opens the PR, folds its url into the completion summary
via `build_completion_summary` (`autonomy/run.sh:4644`, reached through
`emit_completion_summary` at `autonomy/run.sh:5064`, called at `:24804` and
`:25026`), and then prints instructions to create the PR it just created. That
is a contradictory instruction at the moment the user is deciding whether the
job is done.

The same hand-back shape appears on the pause path: the guidance written into
`PAUSED.md` (`autonomy/run.sh:25778`) tells the user to read the findings file,
fix what it names, and resume.

## What works, and should not be disturbed

Stated so the defect list is not mistaken for a verdict on the whole system.

- The Evidence Receipt is automatic, not a second command. `loki proof` is an
  inspection surface; generation happens in-run via `generate_proof_of_run`
  (`autonomy/run.sh:7926`), default on (`LOKI_PROOF:-1`), called from
  `main()` at `autonomy/run.sh:26811`, `:26895`, `:26980` and from `cleanup()`
  at `autonomy/run.sh:26016`.
- That receipt survives a gate-stuck exit 20. `autonomy/run.sh:26783` is
  `run_autonomous "$PRD_PATH" || result=$?`, which catches the 20, and the
  zombie-receipt guard at `autonomy/run.sh:26802-26812` generates the proof
  immediately after the loop returns.
- PRs that are opened carry the receipt inline: `autonomy/run.sh:5331` and
  `:9257`, plus the issue path at `autonomy/loki:10779-10793`.
- The receipt is independently re-checkable, which is the substantive answer to
  "does the user get proof they can verify." `cmd_verify` (`autonomy/loki:18131`)
  has a `--fast` path through `lib/fast_verify.py` that runs only exogenous,
  deterministic checks with no model call and no network, so any third party
  with the same commit re-derives the same verdict; the deeper route is
  `autonomy/verify.sh`. `loki proof verify <id>` (`autonomy/loki:36196`)
  re-checks a receipt for tamper and drift, with `--jwks` for attestation
  against a published key set.
- The stuck-gate valve itself is sound. `_loki_gate_stuck` skips the static
  banner and compares the first real cause line
  (`autonomy/run.sh:11132-11145`), so a run making genuine progress through
  different findings is not misread as stuck.

## Refuted during this audit

Recorded so neither is raised again.

- "`enforce_mock_integrity || true` at `autonomy/run.sh:24187` discards the
  BLOCK." False. The verdict travels via the global
  `_LOKI_MOCK_INTEGRITY_STATUS`, read on the next line
  (`autonomy/run.sh:24188`); the `fail` arm runs `track_gate_failure`,
  escalation guidance, and the `_loki_gate_stuck` abort
  (`autonomy/run.sh:24190-24228`). The `|| true` only prevents `set -e` from
  killing the script.
- "The receipt is lost on the gate-stuck path." False, refuted by
  `autonomy/run.sh:26783` and `:26810-26812` as described above.

## Ranked summary

| # | Break | Evidence | Pain |
|---|---|---|---|
| 1 | Gate escalation forces a PAUSE that waits forever, no timeout, no tty guard | `run.sh:24473-24477`, `run.sh:25793-25818`, defaults `run.sh:1513-1515` | Run stalls silently in `--bg`; the failing loop the demand names |
| 2 | Gate-stuck exit 20 ends the run without opening a PR | `run.sh:11098`, `:24101`, `:24227`, `:24275`; PR only at `:24803`, `:25025`, `:25661` | Work exists on a branch the user must find and finish |
| 3 | No cost-per-completed-task; only per-iteration | `loki:6447`, `:6518`; cost `loki:28461` and tasks `loki:28514` never divided | "Least cost per task" is unmeasurable today |
| 4 | No task-value-per-dollar metric | 0 hits with positive control; `loki:28535-28545` is a fixed 15-min multiplier | The demand's headline metric does not exist |
| 5 | No-flag issue run never uses its own PR block; PR depends on a guard chain with three silent no-ops, then teardown prints advice for the PR it already opened | `loki:10762` unreached (`loki:2602`, `:10330`); `run.sh:5279`, `:5282`, `:5287-5290`; `run.sh:9175` + `git-pr-advisory.sh:69-111` | Deliverable can vanish silently on the headline use case; contradictory closing instruction |
