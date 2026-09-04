#!/usr/bin/env bash
#
# workshop-setup.sh
#
# Idempotent provisioning script for Claude Code workshop Mac minis.
# Run from a USB stick on each machine. Re-running on a fully-set-up
# machine is safe and fast — every step has a guard and skips if done.
#
# Resets Claude Code state (memories, projects, plugins, settings) on
# every run while preserving the macOS Keychain login. Designed so the
# same machine can be reset between workshop sessions.
#
# Tested on macOS 13+. Supports Apple Silicon and Intel.
#
# Usage:  bash workshop-setup.sh
#

set -euo pipefail

# ---------- config -------------------------------------------------------

JAVA_VERSION="25.0.3-tem"

NPM_GLOBALS=(
  "typescript-language-server"
  "typescript"
  "pyright"
  "@playwright/cli@latest"
)

# Browsers provisioned for the playwright-cli skill. Leave empty to install
# every browser the bundled playwright knows about (chromium + headless
# shell, firefox, webkit, ffmpeg). Narrow to e.g. (chromium) to cut
# per-machine provisioning time.
PLAYWRIGHT_BROWSERS=()

CASKS=(
  docker-desktop
  visual-studio-code
  intellij-idea-ce
  google-chrome
  slack
)

BREW_FORMULAS=(
  node
  jdtls
)

CLAUDE_PLUGINS=(
  context7
  jdtls-lsp
  pyright-lsp
  typescript-lsp
)

CLAUDE_MARKETPLACE_NAME="claude-plugins-official"
CLAUDE_MARKETPLACE_SOURCE="anthropics/claude-plugins-official"

WORKSHOP_DIR="$HOME/workshop"

# Content shipped alongside this script (on the USB stick): skills/ is
# installed into the attendees' workshop directory as project skills, and
# agents/CLAUDE.md becomes that directory's project memory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILLS_SRC="$SCRIPT_DIR/skills"
AGENTS_SRC="$SCRIPT_DIR/agents"

# ---------- helpers ------------------------------------------------------

bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
info()   { printf '  %s\n' "$*"; }
ok()     { printf '  \033[32m✓\033[0m %s\n' "$*"; }
skip()   { printf '  \033[90m·\033[0m %s\n' "$*"; }
warn()   { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
fail()   { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

step_n=0
step() {
  step_n=$((step_n + 1))
  echo
  bold "[$step_n] $*"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ---------- preflight ----------------------------------------------------

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "This script only runs on macOS."
}

detect_brew_prefix() {
  case "$(uname -m)" in
    arm64)  BREW_PREFIX="/opt/homebrew" ;;
    x86_64) BREW_PREFIX="/usr/local" ;;
    *)      fail "Unsupported architecture: $(uname -m)" ;;
  esac
}

# `xcode-select -p` on its own is NOT a usable check: it prints whatever
# path is recorded in /var/db/xcode_select_link and exits 0. It succeeds on
# machines where the tools were never fully installed, were gutted by a
# macOS upgrade, or are missing their SDK — which is how some workshop Mac
# minis passed preflight and then died at the first `git` or node-gyp call.
#
# So verify the toolchain end to end instead:
#   1. a developer directory is selected and actually exists
#   2. an install receipt is present (CLT package, or a real Xcode.app)
#   3. xcrun resolves clang/git/make to real binaries, not the /usr/bin
#      stub shims that ship with every macOS and only pop the installer
#   4. a macOS SDK is present
#   5. clang really compiles and links a trivial program
#   6. if full Xcode is selected, its license has been accepted

clt_developer_dir() {
  xcode-select -p 2>/dev/null || true
}

clt_receipt_present() {
  pkgutil --pkg-info=com.apple.pkg.CLTools_Executables >/dev/null 2>&1
}

# A real tool lives under the developer dir; the pre-install stubs live in
# /usr/bin and exit non-zero with "no developer tools were found".
clt_tool_works() {
  local tool="$1" path
  path="$(xcrun --find "$tool" 2>/dev/null)" || return 1
  [[ -n "$path" && -x "$path" ]] || return 1
  case "$path" in
    /usr/bin/*) return 1 ;;
  esac
  "$path" --version >/dev/null 2>&1
}

clt_sdk_present() {
  local sdk
  sdk="$(xcrun --show-sdk-path 2>/dev/null)" || return 1
  [[ -n "$sdk" && -d "$sdk" ]]
}

clt_can_compile() {
  local tmp rc=0
  tmp="$(mktemp -d)" || return 1
  cat >"$tmp/probe.c" <<'PROBE'
int main(void) { return 0; }
PROBE
  xcrun clang -o "$tmp/probe" "$tmp/probe.c" >/dev/null 2>&1 || rc=1
  [[ $rc -eq 0 && -x "$tmp/probe" ]] || rc=1
  rm -rf "$tmp"
  return $rc
}

ensure_xcode_clt() {
  local dev_dir tool f
  local failures=()

  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    warn "DEVELOPER_DIR is set to '${DEVELOPER_DIR}' — it overrides xcode-select."
  fi

  dev_dir="$(clt_developer_dir)"

  if [[ -z "$dev_dir" ]]; then
    failures+=("no developer directory selected (xcode-select -p failed)")
  elif [[ ! -d "$dev_dir" ]]; then
    failures+=("selected developer directory does not exist: $dev_dir")
  else
    if [[ "$dev_dir" == *.app/* ]]; then
      if [[ ! -x "$dev_dir/usr/bin/xcodebuild" ]]; then
        failures+=("Xcode selected at $dev_dir but xcodebuild is missing")
      elif ! xcodebuild -version >/dev/null 2>&1; then
        failures+=("Xcode license not accepted (run: sudo xcodebuild -license accept)")
      fi
    elif ! clt_receipt_present; then
      failures+=("no Command Line Tools receipt (com.apple.pkg.CLTools_Executables)")
    fi

    for tool in clang git make; do
      clt_tool_works "$tool" \
        || failures+=("'$tool' does not resolve to a working developer tool")
    done

    clt_sdk_present || failures+=("no usable macOS SDK (xcrun --show-sdk-path)")
    clt_can_compile || failures+=("clang cannot compile and link a trivial program")
  fi

  if [[ ${#failures[@]} -eq 0 ]]; then
    ok "Xcode Command Line Tools verified ($dev_dir)."
    return
  fi

  warn "Xcode Command Line Tools are not usable:"
  for f in "${failures[@]}"; do
    printf '      \033[33m-\033[0m %s\n' "$f" >&2
  done

  # A present-but-broken install has to be removed first: `xcode-select
  # --install` just reports "already installed" and changes nothing.
  if [[ -n "$dev_dir" ]] && { clt_receipt_present || [[ -d "$dev_dir" ]]; }; then
    cat >&2 <<EOF

  The tools are partially installed, so the installer will refuse to run.
  Wipe and reinstall them, then re-run this script:

      sudo rm -rf /Library/Developer/CommandLineTools
      xcode-select --switch /Library/Developer/CommandLineTools 2>/dev/null || true
      xcode-select --install

EOF
    exit 1
  fi

  warn "Launching the Command Line Tools installer."
  xcode-select --install || true
  cat >&2 <<EOF

  A GUI dialog has opened. Click "Install" and wait for it to finish
  (this can take 5–15 minutes). Then re-run this script.

EOF
  exit 1
}

# ---------- sudo priming -------------------------------------------------

# Homebrew's installer (with NONINTERACTIVE=1) calls `sudo -n` and aborts
# with "Need sudo access on macOS!" if there's no cached sudo timestamp —
# the default on a brand-new Mac. Prime sudo here, then keep the
# timestamp warm in the background for the multi-minute Homebrew install
# (default sudo timeout is 5 minutes).
prime_sudo() {
  # If a keepalive from a prior exec is still running, adopt it.
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
    skip "Sudo already primed (keepalive PID $SUDO_KEEPALIVE_PID)."
    return
  fi

  if ! sudo -n true 2>/dev/null; then
    info "Homebrew's installer needs sudo. Enter your login password when prompted."
    sudo -v || fail "sudo authentication failed."
  fi
  ok "Sudo access primed."

  ( while true; do sudo -n true 2>/dev/null || exit; sleep 50; done ) &
  export SUDO_KEEPALIVE_PID=$!
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
}

# ---------- homebrew -----------------------------------------------------

install_homebrew() {
  if have_cmd brew; then
    ok "Homebrew already installed at $(brew --prefix)."
  else
    info "Installing Homebrew (non-interactive)…"
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    ok "Homebrew installed."
  fi
  # Make brew available in this shell regardless of zshrc state.
  eval "$("$BREW_PREFIX/bin/brew" shellenv)"
}

# Rest of this script needs bash 4+ features (associative arrays, etc.);
# macOS ships bash 3.2. Install a modern bash from Homebrew up front.
install_modern_bash() {
  if brew list --formula bash >/dev/null 2>&1; then
    skip "bash already installed via brew ($("$BREW_PREFIX/bin/bash" --version | head -1))."
  else
    info "Installing bash (need 4+ for the rest of the script)…"
    brew install bash
    ok "bash installed: $("$BREW_PREFIX/bin/bash" --version | head -1)"
  fi
}

install_casks() {
  for cask in "${CASKS[@]}"; do
    if brew list --cask "$cask" >/dev/null 2>&1; then
      skip "$cask already installed (via brew)."
      continue
    fi
    # A manually-installed app at /Applications/Foo.app blocks
    # `brew install --cask`. Workshop only needs the app present, so
    # leave a pre-existing install alone instead of forcing or adopting.
    local app_name
    app_name="$(brew info --cask "$cask" 2>/dev/null \
      | sed -n 's/^\(.*\.app\) (App)$/\1/p' | head -1)"
    if [[ -n "$app_name" ]] && [[ -d "/Applications/$app_name" ]]; then
      skip "$cask: /Applications/$app_name already present (not via brew)."
      continue
    fi
    info "Installing cask: ${cask}…"
    brew install --cask "$cask"
    ok "$cask installed."
  done
}

install_brew_formulas() {
  for formula in "${BREW_FORMULAS[@]}"; do
    if brew list --formula "$formula" >/dev/null 2>&1; then
      skip "$formula already installed."
    else
      info "Installing formula: ${formula}…"
      brew install "$formula"
      ok "$formula installed."
    fi
  done
}

# ---------- sdkman + java + maven + gradle -------------------------------

install_sdkman() {
  if [[ -d "$HOME/.sdkman" ]]; then
    ok "SDKMAN already installed."
  else
    info "Installing SDKMAN…"
    curl -fsSL "https://get.sdkman.io?rcupdate=false" | bash
    ok "SDKMAN installed."
  fi
  # Auto-answer Y/N prompts (e.g. "set as default?") for non-interactive runs.
  local cfg="$HOME/.sdkman/etc/config"
  if [[ -f "$cfg" ]] && ! grep -q '^sdkman_auto_answer=true' "$cfg"; then
    sed -i.bak 's/^sdkman_auto_answer=.*/sdkman_auto_answer=true/' "$cfg"
    rm -f "$cfg.bak"
  fi
  # SDKMAN's init script and `sdk` function reference variables like
  # $ZSH_VERSION without guarding for unset, so relax nounset for the
  # source and for any `sdk` invocation downstream.
  set +u
  # shellcheck disable=SC1091
  source "$HOME/.sdkman/bin/sdkman-init.sh"
  set -u
}

install_sdkman_candidate() {
  local candidate="$1" version="${2:-}"
  local label
  if [[ -n "$version" ]]; then
    label="$candidate $version"
  else
    label="$candidate (latest)"
  fi

  if [[ -n "$version" ]] && [[ -d "$HOME/.sdkman/candidates/$candidate/$version" ]]; then
    skip "$label already installed."
    return
  fi
  if [[ -z "$version" ]] && [[ -d "$HOME/.sdkman/candidates/$candidate/current" ]]; then
    skip "$label already installed (some version)."
    return
  fi

  info "Installing $label via SDKMAN…"
  set +u
  if [[ -n "$version" ]]; then
    sdk install "$candidate" "$version" </dev/null
  else
    sdk install "$candidate" </dev/null
  fi
  set -u
  ok "$label installed."
}

# ---------- claude code (native install) ---------------------------------

install_claude_code() {
  if have_cmd claude && claude --version >/dev/null 2>&1; then
    ok "Claude Code already installed: $(claude --version 2>&1 | head -n1)"
  else
    info "Installing Claude Code via official native installer…"
    curl -fsSL https://claude.ai/install.sh | bash
    # Native installer puts binary at ~/.local/bin/claude.
    export PATH="$HOME/.local/bin:$PATH"
    if ! have_cmd claude; then
      fail "Claude install ran but \`claude\` not on PATH."
    fi
    ok "Claude Code installed: $(claude --version 2>&1 | head -n1)"
  fi
  # Always ensure ~/.local/bin is on PATH for this shell.
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac
}

# ---------- wipe claude state (preserve keychain login) ------------------

wipe_claude_state() {
  # Wipe ~/.claude/ contents (memories, plugins, skills, projects,
  # sessions, settings, cache, history, plans). Plugins + skills get
  # reinstalled later. We delete contents but leave the directory itself
  # so a concurrently-running `claude` session that recreates state
  # mid-wipe can't race us at the parent-dir removal step.
  #
  # ~/.claude.json is intentionally left untouched: it holds the
  # `oauthAccount` reference that pairs with the bearer token in the
  # macOS Keychain. Modifying or removing it forces attendees to log in
  # again on the next launch.
  if [[ -d "$HOME/.claude" ]]; then
    find "$HOME/.claude" -mindepth 1 -depth -exec rm -rf {} + 2>/dev/null || true
    ok "Wiped ~/.claude/ (memories, plugins, skills, sessions, settings)."
  else
    skip "~/.claude/ already absent."
  fi

  # Wipe project-local Claude state in the workshop directory.
  rm -rf "$WORKSHOP_DIR/.claude" "$WORKSHOP_DIR/.mcp.json" 2>/dev/null || true
  ok "Wiped any project-local Claude state in $WORKSHOP_DIR."
}

# ---------- claude marketplace + plugins ---------------------------------

ensure_claude_marketplace() {
  if claude plugin marketplace list 2>/dev/null | grep -q "$CLAUDE_MARKETPLACE_NAME"; then
    skip "Marketplace $CLAUDE_MARKETPLACE_NAME already configured."
  else
    info "Adding marketplace ${CLAUDE_MARKETPLACE_SOURCE}…"
    claude plugin marketplace add "$CLAUDE_MARKETPLACE_SOURCE" </dev/null
    ok "Marketplace added."
  fi
}

install_claude_plugins() {
  for plugin in "${CLAUDE_PLUGINS[@]}"; do
    if claude plugin list 2>/dev/null | grep -qE "^[[:space:]]*[^[:space:]]+[[:space:]]+$plugin@$CLAUDE_MARKETPLACE_NAME"; then
      skip "Plugin $plugin already installed."
    else
      info "Installing plugin ${plugin}@${CLAUDE_MARKETPLACE_NAME}…"
      claude plugin install "$plugin@$CLAUDE_MARKETPLACE_NAME" </dev/null
      ok "$plugin installed."
    fi
  done
}

# ---------- npm globals + playwright -------------------------------------

install_npm_globals() {
  for pkg in "${NPM_GLOBALS[@]}"; do
    # Resolve package name (strip version specifier; preserve @scope/ prefix).
    local name
    case "$pkg" in
      @*/*) name="$(printf '%s' "$pkg" | sed -E 's|^(@[^/]+/[^@]+).*|\1|')" ;;
      *)    name="${pkg%@*}" ;;
    esac

    if npm list -g --depth=0 "$name" >/dev/null 2>&1; then
      skip "npm global $name already installed."
    else
      info "Installing npm global: ${pkg}…"
      npm install -g "$pkg"
      ok "$name installed."
    fi
  done
}

# Browsers come from playwright-cli, not `npx playwright install`. npx
# resolves the standalone `playwright` package, which pins a *different*
# version from the playwright-core that @playwright/cli bundles — so it
# downloads a second, never-loaded set of browsers while leaving the set
# playwright-cli actually uses incomplete. Observed on a provisioned mini:
# npx pulled 1.62.1 (chromium-1234) while playwright-cli ships
# 1.61.0-alpha, whose chromium was never downloaded at all.
#
# `install-browser` with no argument covers every browser the bundled
# playwright knows about, and is idempotent — already-present browsers are
# skipped in well under a second.
install_playwright_browsers() {
  if ! have_cmd playwright-cli; then
    fail "playwright-cli not on PATH after npm install — cannot install browsers."
  fi
  info "Ensuring Playwright browsers are installed…"
  if (( ${#PLAYWRIGHT_BROWSERS[@]} == 0 )); then
    playwright-cli install-browser
  else
    local browser
    for browser in "${PLAYWRIGHT_BROWSERS[@]}"; do
      info "browser: ${browser}…"
      playwright-cli install-browser "$browser"
    done
  fi
  ok "Playwright browsers ready."
}

install_playwright_skill() {
  local skill_dir="$HOME/.claude/skills/playwright-cli"

  # No existence guard here on purpose: wipe_claude_state empties
  # ~/.claude/ earlier in the same run, so the skill is always absent by
  # the time we get here and any "already registered" skip would be dead
  # code. Registration is cheap, so just always do it.
  if ! have_cmd playwright-cli; then
    fail "playwright-cli not on PATH after npm install — cannot register skill."
  fi
  info "Registering playwright-cli skill for Claude Code…"
  # `playwright-cli install --skills` always writes to ./.claude/skills/ of
  # the current working directory. Run it from $HOME so the skill lands at
  # $HOME/.claude/skills/playwright-cli/ (user-global) instead of next to
  # the script on the USB stick.
  ( cd "$HOME" && playwright-cli install --skills )
  # patch_playwright_skill_headed silently skips a missing SKILL.md, which
  # would quietly cost us the headed default — so fail loudly here instead.
  [[ -f "$skill_dir/SKILL.md" ]] \
    || fail "playwright-cli install --skills did not create $skill_dir/SKILL.md."
  ok "playwright-cli skill registered at $skill_dir."
}

# Inject a "Default to headed" rule at the top of the playwright-cli SKILL.md
# so Claude opens browsers visibly by default in this workshop. Without this,
# the skill's own examples (`playwright-cli open` with no flag) train Claude
# to launch headless, even with a project CLAUDE.md saying otherwise — the
# example pattern wins over the prose rule. Patching the skill itself makes
# the default portable across every project on this machine.
#
# Idempotent via sentinel "## Default to headed". Append-only (no edits to
# upstream examples) so it survives skill upgrades.
patch_playwright_skill_headed() {
  local skill_file="$HOME/.claude/skills/playwright-cli/SKILL.md"
  if [[ ! -f "$skill_file" ]]; then
    skip "playwright-cli SKILL.md not present — nothing to patch."
    return
  fi
  if grep -q '^## Default to headed' "$skill_file"; then
    skip "playwright-cli SKILL.md already has 'Default to headed' rule."
    return
  fi

  info "Injecting 'Default to headed' rule into playwright-cli SKILL.md…"
  local awk_script tmp
  awk_script="$(mktemp)"
  tmp="$(mktemp)"
  cat > "$awk_script" <<'AWKEOF'
BEGIN { state = "before_h1" }
state == "before_h1" && /^# / { print; state = "after_h1"; next }
state == "after_h1" && /^$/ {
  print
  print "## Default to headed"
  print ""
  print "**Always pass `--headed` to `playwright-cli open` unless the user explicitly asks for headless or the context makes headless clearly correct (e.g. CI, a remote server with no display).** A visible browser lets the user see what's happening, which is the whole point of running this tool interactively. If you're unsure whether headed is wanted, ask before opening. This default applies to every example below — when you adapt one, keep the `--headed` flag."
  print ""
  state = "done"
  next
}
{ print }
AWKEOF

  awk -f "$awk_script" "$skill_file" > "$tmp"
  rm -f "$awk_script"

  if ! grep -q '^## Default to headed' "$tmp"; then
    rm -f "$tmp"
    fail "Failed to inject 'Default to headed' (no H1 found in $skill_file?)."
  fi
  mv "$tmp" "$skill_file"
  ok "Injected 'Default to headed' rule into $skill_file."
}

# ---------- workshop dir + CLAUDE.md -------------------------------------

ensure_workshop_dir() {
  if [[ ! -d "$WORKSHOP_DIR" ]]; then
    mkdir -p "$WORKSHOP_DIR"
    ok "Created $WORKSHOP_DIR."
  else
    skip "$WORKSHOP_DIR already exists."
  fi

  # Rewritten on every run, like the skills: CLAUDE.md is provisioned
  # content, not attendee work. Without this a previous attendee's edits
  # would carry into the next session, since the file sits beside
  # $WORKSHOP_DIR/.claude rather than inside it and so escapes the wipe.
  #
  # The source of truth is agents/CLAUDE.md on the stick rather than a
  # heredoc in this script, so the memory can be edited and reviewed as
  # the markdown file it ends up being. A missing source leaves whatever
  # is on the machine alone rather than writing an empty memory.
  local src="$AGENTS_SRC/CLAUDE.md"
  local claude_md="$WORKSHOP_DIR/CLAUDE.md"
  local verb="Wrote"

  if [[ ! -f "$src" ]]; then
    warn "No CLAUDE.md at $src — leaving $claude_md as-is."
    return
  fi

  if [[ -f "$claude_md" ]] && cmp -s "$src" "$claude_md"; then
    skip "$claude_md already up to date."
    return
  fi

  if [[ -f "$claude_md" ]]; then
    verb="Replaced"
  fi
  cp "$src" "$claude_md"
  ok "$verb $claude_md."
}

# ---------- workshop skills ----------------------------------------------

# Claude Code discovers project skills at <project>/.claude/skills/<name>/
# SKILL.md, so copying the stick's skills/ there makes them load for anyone
# running `claude` from ~/workshop — no marketplace, no install step.
#
# Must run AFTER wipe_claude_state, which removes $WORKSHOP_DIR/.claude
# wholesale. The destination is rebuilt from the stick on every run: a skill
# renamed or dropped on the stick disappears from the machine too, and
# attendee edits to these skills do not survive a re-run. That's deliberate —
# skills are provisioned content, not attendee work.
install_workshop_skills() {
  local dest="$WORKSHOP_DIR/.claude/skills"
  local staging="$WORKSHOP_DIR/.claude/skills.staging"
  local skill name count=0

  if [[ ! -d "$SKILLS_SRC" ]]; then
    warn "No skills directory at $SKILLS_SRC — leaving $dest as-is."
    return
  fi

  # Staged into a sibling directory and swapped in only once at least one
  # valid skill has been copied, so a missing or malformed source can never
  # leave the machine with an empty skills directory.
  rm -rf "$staging"
  mkdir -p "$staging"

  for skill in "$SKILLS_SRC"/*/; do
    [[ -d "$skill" ]] || continue
    name="$(basename "$skill")"
    if [[ ! -f "$skill/SKILL.md" ]]; then
      warn "$name has no SKILL.md — not a skill, skipping."
      continue
    fi
    cp -R "$skill" "$staging/$name"
    count=$((count + 1))
    info "Installed skill: $name"
  done

  if (( count == 0 )); then
    rm -rf "$staging"
    warn "No valid skills found in $SKILLS_SRC — leaving $dest as-is."
    return
  fi

  # Working files that ride along in the source tree — playwright-cli logs,
  # Finder metadata, Python caches — are not part of a skill.
  find "$staging" -type d \( -name '.playwright-cli' -o -name '__pycache__' \) \
    -prune -exec rm -rf {} + 2>/dev/null || true
  find "$staging" -name '.DS_Store' -delete 2>/dev/null || true

  rm -rf "$dest"
  mv "$staging" "$dest"
  ok "$count skill(s) installed to $dest."
}

# ---------- shell rc updates ---------------------------------------------

ensure_zshrc_block() {
  local marker="$1" body="$2"
  local zshrc="$HOME/.zshrc"
  touch "$zshrc"
  if grep -qF "# >>> workshop-setup: $marker >>>" "$zshrc"; then
    skip "~/.zshrc block '$marker' already present."
    return
  fi
  {
    echo
    echo "# >>> workshop-setup: $marker >>>"
    echo "$body"
    echo "# <<< workshop-setup: $marker <<<"
  } >> "$zshrc"
  ok "Appended ~/.zshrc block: $marker."
}

configure_shell_env() {
  ensure_zshrc_block "brew" "eval \"\$(\"$BREW_PREFIX/bin/brew\" shellenv)\""

  ensure_zshrc_block "local-bin" \
'export PATH="$HOME/.local/bin:$PATH"'

  ensure_zshrc_block "sdkman" \
'export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]] && source "$SDKMAN_DIR/bin/sdkman-init.sh"'
}

# ---------- summary ------------------------------------------------------

print_summary() {
  echo
  bold "Setup complete."
  cat <<EOF

  Next steps for the workshop user:

    1. Open a NEW terminal (so ~/.zshrc additions take effect), or run:
         exec zsh -l

    2. Launch Claude Code:
         cd ~/workshop
         claude

       On a fresh machine, log in with the Claude Console account the
       org invited you to — a browser opens automatically. On later runs
       the macOS Keychain remembers the login, so this is a one-time step
       per machine.

    3. Verify the toolbox:
         claude --version
         claude plugin list
         java -version           # should report 25.0.3-tem
         mvn --version
         gradle --version
         playwright-cli --help
         ls ~/workshop/.claude/skills   # provisioned project skills

  Re-run this script anytime to wipe Claude state (memories, projects,
  plugins) and reset the machine to a fresh workshop state. Login is
  preserved: the Keychain (OAuth) and ~/.claude.json (API-key approval)
  are both left untouched.

EOF
}

# ---------- main ---------------------------------------------------------

main() {
  bold "Claude Code workshop setup"
  info "Host: $(hostname) — arch: $(uname -m) — user: $USER"

  step "Preflight";                 require_macos; detect_brew_prefix; ensure_xcode_clt
  step "Sudo access";               prime_sudo
  step "Homebrew";                  install_homebrew
  step "Modern bash (4+)";          install_modern_bash

  # macOS ships /bin/bash 3.2; the rest of this script needs 4+. If
  # we're still running on legacy bash, re-exec under the bash we just
  # installed. The script restarts from the top — every step above is
  # idempotent and no-ops on the second pass.
  if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
    info "Re-executing under $BREW_PREFIX/bin/bash (was bash ${BASH_VERSION})…"
    exec "$BREW_PREFIX/bin/bash" "$0" "$@"
  fi

  step "Casks";                     install_casks
  step "Brew formulas";             install_brew_formulas
  step "SDKMAN";                    install_sdkman
  step "Java 25 Temurin";           install_sdkman_candidate java "$JAVA_VERSION"
  step "Maven";                     install_sdkman_candidate maven
  step "Gradle";                    install_sdkman_candidate gradle
  step "Claude Code (native)";      install_claude_code
  step "Wipe Claude state";         wipe_claude_state
  step "Claude marketplace";        ensure_claude_marketplace
  step "Claude plugins";            install_claude_plugins
  step "npm globals";               install_npm_globals
  step "Playwright browsers";       install_playwright_browsers
  step "Playwright CLI skill";      install_playwright_skill
  step "Default playwright headed"; patch_playwright_skill_headed
  step "Workshop dir + CLAUDE.md";  ensure_workshop_dir
  step "Workshop skills";           install_workshop_skills
  step "Shell init (~/.zshrc)";     configure_shell_env

  print_summary
}

main "$@"
