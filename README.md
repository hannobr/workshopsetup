# Workshop setup — Mac mini provisioning

A single Bash script that prepares a Mac mini for a Claude Code workshop.

## Usage

Plug in the USB stick and run:

```bash
bash /Volumes/<usb-name>/workshop-setup/workshop-setup.sh
```

Or, if copied to the machine first:

```bash
bash ~/workshop-setup/workshop-setup.sh
```

The script is idempotent — re-running it on a fully provisioned machine
finishes in seconds with every step reporting "already installed".

## What it does

1. **Preflight** — ensures Xcode Command Line Tools are present (launches
   the GUI installer if missing; you must wait for it to finish and
   re-run the script).
2. **Homebrew** — installs if missing.
3. **Casks** — Docker Desktop, Visual Studio Code, IntelliJ IDEA CE,
   Google Chrome, Slack.
4. **Brew formulas** — Node.js, jdtls (Eclipse Java language server).
5. **SDKMAN** — installs Java 25 Temurin, Maven, and Gradle.
6. **Claude Code** — official native installer (not the brew cask).
7. **Resets Claude Code state** while preserving login (see below).
8. **Claude plugins** — adds the `claude-plugins-official` marketplace
   and installs: `context7`, `jdtls-lsp`, `pyright-lsp`,
   `typescript-lsp`.
9. **npm globals** — `typescript-language-server`, `typescript`,
   `pyright`, `@playwright/cli`.
10. **Playwright browsers** — `npx playwright install`.
11. **Playwright skill** — registers the official Microsoft
    `playwright-cli` skill so Claude Code auto-discovers it. Note: this
    is the **CLI + skill** approach, not the Playwright MCP server.
12. **`~/workshop/`** — created if missing, with `agents/CLAUDE.md`
    copied from the stick as its project memory: a stack-agnostic file
    directing Claude to use Playwright for end-to-end verification and
    to build UI work against the `product-standards` and
    `design-standards` skills. **Rewritten on every run** (see
    [Project memory](#project-memory) and
    [State reset behavior](#state-reset-behavior)).
13. **`~/.zshrc`** — appends idempotent (marker-fenced) blocks for
    Homebrew shellenv, `~/.local/bin` on PATH, and SDKMAN init.
14. **Skills** — copies `skills/` from the stick into
    `~/workshop/.claude/skills/` (see [Skills](#skills)).

## Project memory

`agents/CLAUDE.md` in this repo is the workshop project memory. The
script copies it verbatim to `~/workshop/CLAUDE.md`, so Claude Code picks
it up for anyone running `claude` from `~/workshop`. Edit that file to
change what attendees' Claude is told — it is the single source of truth;
the script holds no copy of the text.

Like the skills, it is **provisioned content, not attendee work**: every
run overwrites it, discarding edits made on the machine. Runs that change
nothing report "already up to date" rather than touching the file. If
`agents/CLAUDE.md` is missing from the stick the step warns and leaves
whatever is on the machine alone, rather than writing an empty memory.

## Skills

`skills/` in this repo ships to the machines as **project skills**. Claude
Code discovers them at `<project>/.claude/skills/<name>/SKILL.md`, so the
script copies each one into `~/workshop/.claude/skills/` and they load
automatically for anyone running `claude` from `~/workshop` — no
marketplace, no per-attendee install.

Currently shipped: `design-standards`, `product-standards`,
`skill-creator`.

A source directory needs a `SKILL.md` at its top level to count as a
skill; anything else is skipped with a warning. Playwright-CLI logs,
`__pycache__`, and `.DS_Store` are stripped during the copy.

**The destination is rebuilt from the stick on every run.** A skill
renamed or dropped from `skills/` disappears from the machine, and
attendee edits to these skills do not survive a re-run — they're
provisioned content, not attendee work. The copy is staged in a sibling
directory and swapped in only after at least one valid skill lands, so a
missing or malformed `skills/` leaves the existing install alone rather
than emptying it.

The step runs after the state wipe, which removes `~/workshop/.claude`
wholesale — reordering it earlier would delete the skills it just
installed.

### Scope caveat

Project skills load from `.claude/skills/` in the directory where Claude
Code starts and in every parent up to the **repository root**. Attendees
who start Claude in `~/workshop` get them. An attendee who runs
`git init` in `~/workshop/myapp` and starts Claude there stops the
upward search at that new repo root, and the skills won't load.

If that's a realistic workshop flow, install them personal-scope instead
by pointing `dest` in `install_workshop_skills` at `~/.claude/skills/`,
which applies to every project. That directory is also wiped each run, and
the step already runs after the wipe, so nothing else changes.

## Authentication

Attendees log in with a **Claude Console account on the organisation**.
The admin invites them from the Console (Settings → Members → Invite) with
the **Claude Code** role, which lets them create Claude Code keys and
nothing else.

On first launch `claude` opens a browser for the login. The resulting
credential is stored in the encrypted macOS Keychain, which this script
never touches, so it is a **one-time step per machine** — re-running the
script between sessions does not force a re-login.

Run `/status` inside Claude Code to confirm which account is active.

## State reset behavior

Every run wipes Claude Code working state:

- Empties `~/.claude/` (memories, plugins, skills, projects, sessions,
  settings, cache, history, plans) — the directory itself is left in
  place so a concurrently running `claude` can't race the removal
- Removes `~/workshop/.claude/` and `~/workshop/.mcp.json` if present
- Rewrites `~/workshop/CLAUDE.md` from `agents/CLAUDE.md` on the stick,
  discarding any edits

`CLAUDE.md` sits beside `~/workshop/.claude` rather than inside it, so it
escapes the directory wipe — `ensure_workshop_dir` overwrites it
explicitly instead. Without that, a previous attendee's edits would carry
into the next session. Re-runs that change nothing report "already up to
date" rather than touching the file.

**`~/.claude.json` is deliberately left untouched.** It holds the
`oauthAccount` reference that pairs with the bearer token in the Keychain.
Wiping it would force every attendee back through a login on each reset.

**Login is preserved** — the credential lives in the macOS Keychain and
`~/.claude.json` keeps the account reference; the script touches neither.
Re-running between workshop sessions gives the next attendee clean Claude
Code state without re-authenticating.

## After install

```bash
exec zsh -l            # pick up new ~/.zshrc blocks
cd ~/workshop
claude                 # first run on a machine: log in via Console
```

Verify the toolbox:

```bash
claude --version
claude plugin list
java -version          # 25.0.3-tem
mvn --version
gradle --version
playwright-cli --help
ls ~/workshop/.claude/skills        # design-standards, product-standards, skill-creator
```

## Notes

- **macOS only.** The script refuses to run on other platforms.
- **Apple Silicon and Intel** both supported.
- **First run on a brand-new machine** triggers the Xcode CLT GUI
  installer and exits — wait for it to finish, then re-run.
- **Running on your dev machine** will wipe your Claude Code state
  (memories, projects, history) too. Back up
  `~/.claude/projects/<project>/memory/` first if you care about it.
