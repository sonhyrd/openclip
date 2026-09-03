# ADR 0001 — Isolate the Claude Code CLI invocation

- **Status:** Accepted
- **Date:** 2026-09-03
- **Context:** [#1](https://github.com/sonhyrd/openclip/issues/1) (plan), [#2](https://github.com/sonhyrd/openclip/issues/2) (spec), [#9](https://github.com/sonhyrd/openclip/issues/9) (this record)
- **Shipped in:** [`Sources/Core/AI/ClaudeCLI.swift`](../../Sources/Core/AI/ClaudeCLI.swift), [`Sources/OpenClip/AI/Providers/ClaudeCLIProvider.swift`](../../Sources/OpenClip/AI/Providers/ClaudeCLIProvider.swift), [`Sources/OpenClip/AI/AIServiceManager.swift`](../../Sources/OpenClip/AI/AIServiceManager.swift), [`Sources/Core/Extensions/ShellProcessRunner.swift`](../../Sources/Core/Extensions/ShellProcessRunner.swift)
- **Upstream read for its design:** [`zernonia/mc-grammar`](https://github.com/zernonia/mc-grammar) ADR 0001

This record exists so that the next reader does not "simplify" the isolation away. It describes what
**actually shipped**, with the measurements taken during implementation, not what was intended.

---

## 1. Why this provider exists: subscription, not API key

OpenClip's AI assistant already offers Apple Intelligence, Ollama, a cloud provider and a browser
hand-off. Every cloud path costs an API key and per-token billing. A user who already pays for a
Claude subscription either pays a second time through an API organisation or settles for a weaker
local model — and OpenClip has to ask for, store and safeguard a credential in order to offer
frontier-model quality at all.

Once someone has run `claude login`, the Claude Code CLI answers headless prompts on their
**subscription**. `claude -p "…"` is not an API-key path.

**The invariant: OpenClip handles no credential on this path.** It asks for no API key, stores none,
and actively strips `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` from the child environment so an
API key exported on the machine cannot shadow the subscription login and quietly bill an
organisation instead. The child environment is *assigned* rather than inherited by
`ShellProcessRunner`, so everything the child sees is deliberate.

## 2. The isolation flag set

This is a **blast-radius decision, not a tuning decision.** A text-transform action running on
arbitrary text selected in any application needs no tools, no MCP servers, and none of the user's
project settings. Handing it that ambient configuration is a hazard, not a convenience.

The shipped argument list, in order (`ClaudeCLI.arguments(prompt:)`):

| Flag | Why it is there |
| --- | --- |
| `-p <rules block + stdin sentence>` | Headless print mode, and the carrier for the correction rules. See §3 — this placement is load-bearing. |
| `--max-turns 1` | One shot. There is no conversation here; a second turn is a tool loop we do not want. |
| `--model claude-sonnet-4-5-20250929` | Dated pin, never an alias. See §4. |
| `--setting-sources ""` | Refuses the user's global, project and local settings files. A `CLAUDE.md` in whatever directory the app happens to be in cannot change what a Proofread does. |
| `--tools ""` | Empties the tool surface. A transform on a selection must not be able to read or write files. |
| `--strict-mcp-config` | Refuses the user's MCP servers. The selection cannot reach their tools. |
| `--no-session-persistence` | Nothing about the transformed text is written to disk. See §5. Only valid with `--print`, and `-p` *is* `--print`. |
| `--system-prompt <one-line role>` | Role only, deliberately thin. See §3. |
| `--output-format json` | A single object carrying the error flag and the usage data. See §8 for why not `stream-json`. |

The selected text is **not in the argument list at all** — it arrives over stdin, so quotes,
backticks and newlines in a selection can never be misread as syntax.

Dropping any one of these is an argument to be made explicitly against this ADR, not a
simplification to be slipped in. Ratified on [#1](https://github.com/sonhyrd/openclip/issues/1):

> Carry the isolation flags over intact. `-p`, `--max-turns 1`, `--model <dated pin>`,
> `--setting-sources ""`, `--tools ""`, `--strict-mcp-config`, `--no-session-persistence`,
> `--system-prompt <one-line role>`, `--output-format json`. Dropping one is an argument to be made
> explicitly against ADR 0001, not a simplification to be slipped in. The exact-array test exists to
> make that impossible to do quietly.

### What the isolation flags do **NOT** buy

Stated plainly so this ADR does not over-claim:

**`--tools ""` bounds the TOOLS, not the number of models the CLI runs.** A side-call to a second
model happens regardless — measured, see §10. The flags remove the user's settings files, their MCP
servers and their tool surface from this invocation. **They do not make it a single model call.**

Nor does the flag list prove isolation happened. See §13.

## 3. Prompt placement: rules in `-p`, role in `--system-prompt`

*Credited to upstream `zernonia/mc-grammar` ADR 0001; not re-measured here.*

Moving the correction rules from `-p` into `--system-prompt` measured **7/15** hard-fixture accuracy
against **14/14** with the rules in `-p`.

The half that makes it dangerous: **it fails silently.** The text usually comes back completely
unchanged, looking like "nothing needed fixing". Occasionally the model returns a *list of
corrections* instead of corrected text, and that list is what gets pasted over the user's selection.
No error, no non-zero exit, nothing for error handling to catch.

This is the single most "helpful" refactor available in this code, and it must not be made. The
construction site in `ClaudeCLI.arguments(prompt:)` carries a comment pointing here.

## 4. The dated model pin, and why not an alias

`claude-sonnet-4-5-20250929` — a **dated** identifier, never a floating alias. An alias is what
silently put the upstream project on Opus, at Opus pricing and latency, invisibly. A stale dated
identifier is instead a *visible* maintenance task: the CLI rejects it outright, classification turns
that into `rejectedInvocation`, and the user is told to run `claude update`.

Sonnet rather than the upstream's Haiku: cost was half the upstream's argument for Haiku, and **cost
does not exist on this path** — it is the user's subscription either way. What remains is quality on
Summarize, Explain, Translate and Fix Code, which are real presets here and were not the upstream's
problem.

**The installed CLI knows dated forms of the 4.5-generation identifiers only.** `claude-sonnet-5`,
`claude-opus-5` and `claude-sonnet-4-6` exist **undated**. Pinning one of those would be pinning an
alias — precisely the thing this decision forbids. That is why the pin is 4.5-generation. The pin was
verified to resolve against the installed CLI, as shipped (§10).

There is no model picker. The identifier renders as read-only text in the provider settings.

## 5. Nothing is written to disk

Without `--no-session-persistence`, the CLI writes a session transcript **containing the transformed
text** to `~/.claude/projects/<cwd-slug>/<session>.jsonl`. For a utility acting on arbitrary selected
text from any application, that is a privacy defect, and this repo's conventions keep selected text
privacy-default.

Because the flag is in the asserted array, a later edit that drops it goes red. And if a future CLI
removes the flag, the invocation fails **closed** — `unknown option` → `rejectedInvocation` → a hard
error telling the user to update — rather than silently resuming transcript writing.

## 6. Divergences from upstream — decisions, not porting slips

### 6.1 The `modelUsage` lookup is keyed and log-only

**Upstream's behaviour:** it takes `.values.first` of the model-usage map and treats a missing entry
as a **fatal** malformed response.

**Ours:** the map is read by the pinned identifier **as the key**, and a miss is logged and never
fatal (`ClaudeCLI.modelUsageOutcome`, `ClaudeCLI.ModelUsageOutcome`).

The measurement that forced it: the map has **two** entries under a realistic payload and **one**
under a trivial prompt (§10). Dictionary ordering is undefined, so `.values.first` reports a
different model run to run — and it is wrong *only under realistic input*, which is the worst
possible shape for a bug: a developer smoke-testing with a short string sees a correct log line while
users see a coin flip.

The severity change is the more important half. Ratified wording, quoted verbatim from
[#1](https://github.com/sonhyrd/openclip/issues/1):

> A missing or unexpected `modelUsage` entry is logged, never fatal. The transform succeeded and
> the corrected text is in hand; refusing to hand it to the user because a telemetry field moved is
> the wrong trade in a popup utility. `malformedResponse` is for stdout that does not parse as an
> envelope at all — never for a field inside a valid one.

The lookup is kept rather than deleted because it is the only signal that would ever reveal the pin
no longer resolving to what was requested — exactly what the dated-pin decision exists to keep
visible.

### 6.2 The rejection patterns include the underscored form

The installed CLI emits `[claude-code:unrecognized_model] {…}`. **Upstream's patterns are all
space-separated** (`"unknown model"`, `"invalid model"`) and **none of them match this CLI.**
`ClaudeCLI.rejectedInvocationPatterns` therefore leads with the underscored `unrecognized_model`,
keeping the space-separated forms alongside in case a future version phrases it either way.

Related, from the same measurement: **classify the envelope before the exit code, whenever stdout
parses.** A bad model identifier exits non-zero *and* prints a complete envelope carrying a
human-readable explanation; an exit-code-first classifier buries that message in a generic failure.
And `is_error` is the signal, not `subtype` — a failing run was measured reporting
`subtype: "success"` alongside `is_error: true`, so `subtype` is not even decoded.

### 6.3 The shared executor is reused instead of upstream's own process machinery

Upstream hand-rolls its own `Process`/`DispatchGroup` machinery. This repo's convention is binding:
new subprocess work joins the existing `ShellProcessRunner`. It already solves every problem
upstream's runner solves, and solves one of them **strictly better** — **it signals the whole process
GROUP**, so a grandchild cannot outlive the child while holding the pipes open, **where upstream
signals only the direct child**.

So upstream's *decisions* are carried over — the flag set, login-shell binary resolution, the stdin
discipline, the error taxonomy, the bounded child. Its *process-management code* is not.

**One addition to the executor, and one only:** `runCapturingExit`, which returns the output for any
exit status and throws only on launch failure and timeout. `run` now delegates to it plus a single
non-zero-exit guard, byte-identical in observable behaviour. This was necessary, not cosmetic: the
existing `run` throws with the child's termination status as the error code on a non-zero exit, and
the action-error code **plus one** on timeout — and that constant is 1, so **a timeout and a child
that exits with status 2 were indistinguishable by construction.** The taxonomy this feature needs
cannot be built on that ambiguity.

## 7. Rejected alternatives

- **Capability probing.** Spawning a process on every run to discover which flags the installed CLI
  supports, to guard against a skew that `rejectedInvocation` already surfaces actionably.
- **Graceful degradation on a rejected flag.** Retrying without the flag the CLI refused would
  silently reintroduce the exact hazard the isolation exists to prevent.
- **`--settings <empty-file>`.** It **merges** rather than replaces, so it cannot produce a
  "nothing but what we pass" invocation. `--setting-sources ""` can, and does.
- **A marked private workspace plus a sweep of `~/.claude/projects/`.** It works, and it is what
  upstream does, but it makes OpenClip **delete files in a directory it does not own** on every AI
  run — and `--no-session-persistence` means nothing is written in the first place. Not written is
  strictly better than written-then-deleted: no window in which the text is on disk, no best-effort
  delete that can fail, no shared-state blast radius.

  Credited to upstream, and recorded even though we no longer need it: **do not filter such a sweep
  by modification time.** A transcript that misses its own purge is older than every subsequent
  cutoff, and so survives forever.

## 8. One shot, not streaming — the spinner

The provider's stream yields the finished text exactly **once** and finishes. `--output-format json`
returns a single object, and that object is what carries the error flag and the usage data.
`--output-format stream-json` would mean a second envelope parser for a second shape, and streaming
is out of scope for this feature.

**The user therefore sees a spinner rather than a typewriter** — the only non-browser provider that
does not stream. **Recorded here so it is not "fixed" later by accident.**

## 9. The 30-second orphan window

Cancelling the popup cancels the provider's task but **does not kill the child**: the shared executor
never consults task cancellation. The orphan is bounded by the 30-second watchdog
(`Constants.scriptTimeout`) and nothing more.

Accepted deliberately. Making the executor cancellable would change when *every existing extension's*
subprocess dies, on behalf of extension authors who did not ask for it. **The orphan writes no
transcript**, because it carries `--no-session-persistence` like every other invocation.

## 10. Measurements — measured here, against Claude Code 2.1.259

Every behaviour relied on was measured against the CLI actually installed, rather than assumed from
documentation or inherited from upstream.

- **The designed invocation**, the exact shipped flag list and the shipped pin: `is_error: false`,
  `duration_ms: 2952`, thinking tokens `0`, the result arrived wrapped in `<result>` tags (which the
  existing extraction step already strips), empty stderr, exit 0. An earlier identical-shape run
  measured `duration_ms: 1866`.
- **`MAX_THINKING_TOKENS`**: unset → 91 thinking tokens / 1578 ms. Set to `0` → 0 thinking tokens /
  909 ms. **Identical answer text.** The variable is honoured on this version. It is
  **undocumented**, so it is weaker than a flag; it is decoded and logged, and **deliberately
  asserted by NO test** — a self-test that spends real inference has no place in a hermetic 0-skip
  suite.
- **Transcripts.** *Without* `--no-session-persistence`: the probe text was written to
  `~/.claude/projects/<cwd-slug>/<session>.jsonl` — 3450 bytes, mode 0600 — and `grep -c` found it
  **three times**. *With* the flag: 66 project directories before and 66 after, zero `.jsonl` written,
  and the only machine-wide `grep` hit for the probe string was the authoring session's own
  transcript, not the child's.
- **A bad model identifier**: stderr `[claude-code:unrecognized_model] {...}`, **exit 1**, *and* a
  complete parseable envelope with `is_error: true`, `subtype: "success"`, `api_error_status: 404`,
  and a human-readable `result`. Both the underscore (§6.2) and the classify-before-exit-code rule
  come from this one measurement.
- **`modelUsage` returns TWO entries under a realistic payload** — the pinned
  `claude-sonnet-4-5-20250929` plus `claude-haiku-4-5-20251001`, a side-call the CLI makes itself —
  reproduced across multiple runs including the final pin verification. Under a trivial prompt it
  returns **ONE**. So taking the first entry is wrong *only under realistic input*, which is the
  worst possible shape for a bug.
- **The installed CLI knows dated forms of the 4.5-generation identifiers only.** `claude-sonnet-5`,
  `claude-opus-5` and `claude-sonnet-4-6` exist **undated**. That is why the pin is 4.5-generation.
- **The pin `claude-sonnet-4-5-20250929` was verified to resolve against the installed CLI, as
  shipped.**

## 11. Measurements — credited to upstream, NOT re-measured here

All of the following are from `zernonia/mc-grammar`'s ADR 0001. They are **not** our numbers and were
not reproduced on this machine:

- Isolation cost: **$0.1497 → $0.0003**.
- Isolation latency: **5.51 / 6.59 / 9.47 s → 2.24 / 2.31 / 2.26 s**.
- Roughly **1.4 s** of that floor is **CLI process startup**, and does not move with model choice.
- The prompt-placement result — **7/15 versus 14/14**, with its silent-failure warning (§3).

## 12. The pre-existing localization wrinkle

`String(localized:)` resolves against the **calling bundle**, and the string catalog lives in the app
target while `ClaudeCLI.Failure` lives in the Core framework. Existing Core code already does this;
seen, and deliberately not fixed here — it is pre-existing behaviour affecting existing code, and its
own ticket.

## 13. The honest line about the guard

`ClaudeCLITests` asserts **the array OpenClip constructs**, exactly — one literal array, not
membership, not a subset. That is what stops a later edit quietly dropping `--tools ""`,
`--strict-mcp-config` or `--no-session-persistence`. It asserts the pinned model too, so bumping the
pin is deliberately a two-line change.

**What it does NOT prove:**

- It **cannot detect a CLI version that accepts a flag and ignores it.**
- It **does not prove isolation actually happened.**
- It **never spawns a process.**

**Isolation-in-fact rests on the measurements in §10, not on this test.**

### And the suite could not be executed on the host where this was written

`./scripts/test.sh` and `./scripts/test.sh core` **cannot run on that host.** There is no Xcode
(`xcode-select -p` is `/Library/Developer/CommandLineTools`; `xcodebuild` errors out) and no
`Package.swift` for an SPM route. **Both exit 1 in well under a second without running a single
test**, so there is no baseline duration and no baseline skip count either.

The outcome is therefore **three distinct claims, and they must not be read as one green**:

1. The **flag-list logic** was **red-verified STANDALONE** with `swiftc`: the array was perturbed
   twice — removing `--strict-mcp-config`, and changing `--tools ""` to `--tools "default"` — the
   assertion was watched to fail each time, and then the array was restored.
2. The **XCTest target wiring is UNVERIFIED.** The test file imports the Core framework, which needs
   a build that host cannot produce.
3. **`./scripts/test.sh` is UNMEASURED.** The executor refactor belongs in this unproven list too:
   the existing shell-runtime tests that cover it could not be executed either.

The code is written as though the gate runs, because it will on any machine with Xcode. Nothing about
the design changes. But silence must not read as a pass.
