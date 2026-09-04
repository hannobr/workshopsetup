# Workshop Setup Script — Design

**Date:** 2026-05-09
**Goal:** Single shell script on a USB stick that prepares any Mac mini for a Claude Code workshop. Runs as the logged-in user. Idempotent and re-runnable on any state (fresh OS, partial install, fully provisioned).

## Deliverable

`workshop-setup.sh` — a single Bash script. No external files needed except the script itself.

## What it installs

| # | Tool | Method | Notes |
|---|------|--------|-------|
| 1 | Xcode Command Line Tools | `xcode-select --install` (GUI dialog) | Required for brew. Detected via `xcode-select -p`. |
| 2 | Homebrew | Official install script | Detects Apple Silicon vs Intel for prefix. |
| 3 | Docker Desktop | `brew install --cask docker-desktop` | |
| 4 | Visual Studio Code | `brew install --cask visual-studio-code` | |
| 5 | IntelliJ IDEA CE | `brew install --cask intellij-idea-ce` | CE chosen over Ultimate (free, valid through 2026-12-08). |
| 5a | Google Chrome | `brew install --cask google-chrome` | General use + browser target for Playwright tests. |
| 5b | Slack | `brew install --cask slack` | Workshop comms. |
| 6 | Node.js | `brew install node` | Provides `npm` for LSP binaries. |
| 7 | SDKMAN | Official install script | Skipped if `~/.sdkman` exists. |
| 8 | Java 25 Temurin | `sdk install java 25.0.3-tem` | Via SDKMAN. |
| 8a | Maven | `sdk install maven` | For Spring Boot / `spring init` / ad-hoc `mvn` use. |
| 8b | Gradle | `sdk install gradle` | For Gradle-based Spring Boot projects. |
| 9 | Claude Code | `curl -fsSL https://claude.ai/install.sh \| bash` | **Native installer (NOT brew).** Installs `claude` to `~/.local/bin/claude`. Auto-updates in the background. Idempotency: skip if `command -v claude` already resolves and `claude --version` succeeds. |
| 10 | typescript-language-server | `npm i -g typescript-language-server typescript` | Matches `typescript-lsp` plugin. |
| 11 | pyright | `npm i -g pyright` | Matches `pyright-lsp` plugin. |
| 12 | jdtls | `brew install jdtls` | Matches `jdtls-lsp` plugin. |
| 13 | Playwright CLI | `npm i -g @playwright/cli@latest` | Microsoft's official CLI from `microsoft/playwright-cli`. |
| 14 | Playwright browsers | `npx playwright install` | Chromium/Firefox/WebKit binaries the CLI drives. |
| 15 | Playwright skill | `playwright-cli install --skills` | Microsoft's official `playwright-cli` skill (the SKILL.md bundled in the CLI repo). Auto-discovered by Claude Code. **CLI + skill, not the MCP.** |
| 16 | Claude plugins | `claude plugin install <name>@claude-plugins-official` | context7, jdtls-lsp, pyright-lsp, typescript-lsp. **Note:** two official plugins are intentionally **NOT** installed: `superpowers`, and `playwright` (that's the MCP-based one; we use the CLI skill instead). |
| 17 | `~/workshop/` dir + CLAUDE.md | `mkdir -p ~/workshop && [[ -f ~/workshop/CLAUDE.md ]] \|\| cat > ~/workshop/CLAUDE.md` | Creates the attendee's working directory if missing and seeds it with a stack-agnostic CLAUDE.md (see content below). Skipped entirely if the file already exists — never overwrites attendee work. |

### `~/workshop/CLAUDE.md` content

```markdown
# Workshop project

Use the `playwright-cli` skill to write and run end-to-end tests against
your running application before reporting any change complete. Start the
app, exercise the change through the browser, and verify the full
request/response/render path — regardless of which backend or frontend
stack you've chosen.
```

Stack-agnostic by design: workshop attendees choose their own backend and frontend stacks, so this rule must apply universally rather than naming any specific framework.

## Shell environment

Append to `~/.zshrc` (only if not already present, using bracketed marker comments so re-runs don't duplicate):

```sh
# >>> workshop-setup: brew >>>
eval "$($BREW_PREFIX/bin/brew shellenv)"
# <<< workshop-setup: brew <<<

# >>> workshop-setup: sdkman >>>
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
# <<< workshop-setup: sdkman <<<
```

Where `$BREW_PREFIX` is `/opt/homebrew` on Apple Silicon and `/usr/local` on Intel.

## Idempotency strategy

Every step has a guard. Examples:

- Brew: `command -v brew >/dev/null` → skip
- Cask: `brew list --cask <name> >/dev/null 2>&1` → skip
- SDKMAN: `[[ -d "$HOME/.sdkman" ]]` → skip install, still source it
- Java: `sdk list java | grep -q '25.0.3-tem.*installed'` → skip
- npm globals: `npm list -g --depth=0 <pkg> >/dev/null 2>&1` → skip
- Claude marketplace: `claude plugin marketplace list | grep -q claude-plugins-official` → skip add
- Claude plugin: `claude plugin list | grep -q "^  ❯ <name>@"` → skip install
- Playwright browsers: check existence of `~/Library/Caches/ms-playwright/` and skip the install if Chromium is already present (or just always run `npx playwright install` — it's idempotent natively)
- Playwright skill: check existence of `~/.claude/skills/playwright-cli/` → skip `playwright-cli install --skills`
- zshrc blocks: `grep -q '# >>> workshop-setup: brew >>>' ~/.zshrc` → skip append

Re-running the script on a fully set-up machine should complete in seconds with all steps reporting "already installed".

## Error handling

- `set -euo pipefail` at the top.
- One small `log()` helper that prints `[step N/13] message` with timestamp prefix.
- One `require_macos()` check at the start (refuses to run on Linux).
- One `ensure_xcode_clt()` that, if missing, runs `xcode-select --install` and instructs the user to wait for the GUI dialog to finish, then re-run the script. (We don't want to busy-loop waiting for the dialog.)
- Cask installs sometimes fail with "App already exists" if the user installed manually first — the script will detect existing apps in `/Applications/` and accept brew's "force" or skip mode.

## What is NOT scripted

- **Claude Code OAuth login.** Browser-based, can't be automated. The script ends with a clear printed instruction telling the workshop user to launch the Claude Code app and log in.
- **Per-attendee credentials.** Each Mac mini will be logged into by its workshop user; auth is per-user.

## Non-goals

- Not provisioning macOS user accounts, FileVault, MDM, or any system-level config.
- Not installing the workshop's *exercise project* — that's separate (the existing `/Users/m1/workshop` Java project would be cloned into each attendee's working directory at workshop start, by them).
- Not handling Linux. Mac mini only.

## File layout

```
/Users/m1/workshop-setup/
├── docs/
│   └── 2026-05-09-workshop-setup-design.md   ← this file
├── workshop-setup.sh                          ← the script
└── README.md                                  ← one-page usage instructions for USB
```

## Test plan

1. Run on a fully-set-up Mac (this dev machine) — every step should report "already installed", complete in <30s.
2. Run on a Mac with Homebrew + Node already but nothing else — should layer correctly.
3. (Workshop day) Run on a freshly imaged Mac mini — full install path. Time it. Expect 10–20 minutes depending on network.
