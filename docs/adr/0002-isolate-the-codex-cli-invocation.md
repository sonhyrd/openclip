# ADR 0002 — Isolate the Codex CLI invocation

- **Status:** Accepted
- **Date:** 2026-09-06
- **Context:** [#18](https://github.com/sonhyrd/openclip/issues/18) (ask), [#19](https://github.com/sonhyrd/openclip/issues/19) (spec), [#21](https://github.com/sonhyrd/openclip/issues/21), [#23](https://github.com/sonhyrd/openclip/issues/23), [#24](https://github.com/sonhyrd/openclip/issues/24), [#25](https://github.com/sonhyrd/openclip/issues/25) (this record)
- **Shipped in:** [`Sources/Core/AI/CodexCLI.swift`](../../Sources/Core/AI/CodexCLI.swift), [`Sources/OpenClip/AI/Providers/CodexCLIProvider.swift`](../../Sources/OpenClip/AI/Providers/CodexCLIProvider.swift), [`Sources/OpenClip/AI/AIServiceManager.swift`](../../Sources/OpenClip/AI/AIServiceManager.swift)
- **Builds on:** [ADR 0001](./0001-isolate-the-claude-code-cli-invocation.md), whose isolation invariants are the bar this record is measured against.

This record exists so the next reader does not "simplify" the isolation away, and so the gaps
codex leaves open are read as *named*, not overlooked.

## 1. Why: the same reason as ADR 0001 §1

A user who already pays for a ChatGPT subscription should not need a second API key to get
frontier-model text transforms. Once `codex login` has run, `codex exec` answers headless prompts
on that subscription. OpenClip handles no credential on this path, and strips the variables that
could re-bill or redirect the run (§4).

## 2. The isolation flag set, flag by flag

`codex --help` and `codex exec --help` (codex-cli 0.153.4) are the contract. It is **not** a clone
of `claude`'s flags: `--setting-sources`, `--tools`, `--strict-mcp-config` and
`--no-session-persistence` do not exist, and `codex exec` has **no approval-policy flag** (`-a` is
rejected with `unexpected argument`, measured). The shipped array, in order
(`CodexCLI.arguments(prompt:model:workingDirectory:)`, asserted exactly by `CodexCLITests`):

| Flag | Stands in for | Why it is there |
| --- | --- | --- |
| `exec` | `-p` | Non-interactive. |
| `--ephemeral` | `--no-session-persistence` | No session files. |
| `--ignore-user-config` | `--setting-sources ""` | Skips `~/.codex/config.toml`, where MCP servers and every user setting live. |
| `--ignore-rules` | — | No user or project execpolicy rules. |
| `--disable hooks` | — | Hooks off. See §5: `--ignore-user-config` alone does not stop a trusted hook. |
| `--skip-git-repo-check` | — | The isolated directory is not a repository. |
| `-s read-only`, `-C <empty dir>` | `--tools ""` | Codex has **no tools-off flag**. The shell tool it always carries is confined to reading an empty private folder. A bound, not a removal. |
| `--color never`, `--json` | `--output-format json` | JSONL events on stdout. |
| `-m <wire id>` | `--model` | The user's choice, default `gpt-5.5`, a stable literal. |
| `-c model_reasoning_effort="low"` | — | A one-shot text edit does not want coding-task deliberation. A literal in the array, not a setting. |
| `-c mcp_servers={}` | `--strict-mcp-config` | States the no-MCP invariant in the argument list; fails closed if `--ignore-user-config` ever stops covering it. |
| `<rules prompt>` | `-p <rules>` | The rules block plus a sentence naming the `<stdin>` block. |

The selected text is **not in the argument list**: it goes over stdin, which `codex exec` appends
to the prompt as a `<stdin>` block (its documented contract). Quotes, backticks and newlines in a
selection can never be misread as flags.

Dropping any one of these is an argument to be made against this ADR, not a simplification. The
exact-array test exists to make that impossible to do quietly; it was watched to go red with
`--ephemeral` removed and green again with it restored.

## 3. The named gaps

Stated plainly, so this record does not over-claim:

- **No tools-off flag.** The shell tool exists on every codex run. `-s read-only` plus an empty
  private cwd is the smallest surface the CLI offers. Anything the model can read from that folder
  is nothing.
- **No approval flag on `exec`.** Measured: `-a`/`--ask-for-approval` is an interactive-mode flag
  only. With a read-only sandbox there is nothing to approve, but the flag is not there to pin.
- **MCP removal is by config omission plus the explicit override**, not a dedicated flag. Two
  independent mechanisms, both in the array.
- **`--ephemeral`'s success path is unmeasured** (§5): the host was not logged in.
- **The catalog listing reads the user's config.** `codex debug models` takes no
  `--ignore-user-config` and rejects `--color` (both measured). It shapes only the picker and
  never runs a model. `debug` is a subcommand whose name may move; a rejected listing leaves the
  picker showing the stored slug.

## 4. Environment

Stripped (`CodexCLI.strippedEnvironmentKeys`, asserted as a literal): `OPENAI_API_KEY`,
`CODEX_API_KEY`, `CODEX_ACCESS_TOKEN`, `CODEX_AUTH`, `CODEX_URL` — the names the native codex
binary references (read out of it with `strings`; **it never references `OPENAI_BASE_URL`**, so
that is not listed). `CODEX_HOME` is **kept**: the subscription login lives there, and stripping it
would log the user out. PATH is prefixed the way ADR 0001 does it.

## 5. Measurements — codex-cli 0.153.4, 2026-09-06, offline

All in a throwaway `CODEX_HOME`, none touching the user's own. None cost a model call: a
logged-out run fails at auth, after config and hooks have been processed.

- **`-c mcp_servers={}`** is accepted and reaches the 401. `-c mcp_servers="bogus"` is rejected at
  config load: `Error loading config.toml: invalid type: string "bogus", expected a map`. The
  override is type-validated, so it fails closed.
- **Hooks.** An untrusted `hooks.json` does **not** run (no marker file). With
  `--dangerously-bypass-hook-trust` it runs, and `--ignore-user-config` does **not** stop it.
  `--disable hooks` (= `-c features.hooks=false`) stops it even with trust bypassed. `codex
  features list` reports `hooks stable true`. Hence the flag.
- **`--ephemeral`, failing path.** A marker string in both the prompt and stdin was not found
  anywhere under `CODEX_HOME` after the run. The success path is unmeasured until a login exists.
- **Logged out, `--json`:** exit 1; stdout is JSONL with `{"type":"error","message":"Reconnecting…
  (unexpected status 401 Unauthorized: Missing bearer or basic authentication in header …)"}`
  events; stderr carries tracing lines. `CodexCLI.notAuthenticatedPatterns` lead with that shape.
- **`-a` on exec:** `error: unexpected argument '-a' found`, exit 2. `CodexCLI.rejectedInvocationPatterns`
  lead with that shape.
- **`codex debug models`** renders the catalog while logged out: eleven entries, six with
  `visibility: "list"` (gpt-6-astra, gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5, gpt-5.2),
  five hidden. The picker keeps the listed ones. `--color never` is rejected by `debug`.
- **`codex login status`:** "Not logged in". `codex mcp list`: empty.

## 6. Response handling and the failure taxonomy

Every JSONL line is scanned. The last `item.completed` whose item is an `agent_message` is the
result **unless an error event follows it** or the exit is non-zero; an error *before* the message
(a transport retry that then succeeded) does not fail a transform whose text arrived. The patterns
match error events and stderr only, never an agent message: the model's own words must not be able
to classify the run. `-o <file>` is never used — it writes the transformed text to disk.

`CodexCLI.Failure` mirrors `ClaudeCLI.Failure` case for case with codex wording, as its own type so
neither provider's vocabulary leaks into the other's. All map to the shared provider-unavailable
case. The not-authenticated sentence says `codex login`. The bare word "login" is deliberately
not a pattern: it would match a login shell or a login hook.

## 7. Carried over from ADR 0001 unchanged

One shot, not streaming (the JSONL is read after exit); the shared executor with the shared
watchdog and process-group kill — the orphan bound: a hung codex dies at the watchdog, and a
cancelled popup kills the child with it; the resolution cache on the manager, never persisted; the empty
private cwd; the keyed rules-in-prompt placement.
