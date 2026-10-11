#!/usr/bin/env bash
set -euo pipefail

# Prepare this checkout to build and launch the Cline VS Code extension on Linux.
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

add_path_to_profile() {
	local profile="$1"
	local entry='export PATH="$HOME/.local/bin:$PATH"'
	[[ -f "$profile" ]] || touch "$profile"
	if ! grep -Fq "$entry" "$profile"; then
		printf '\n# User-installed command line tools\n%s\n' "$entry" >> "$profile"
	fi
}

command -v curl >/dev/null 2>&1 || fail "curl is required to install Bun. Install curl and rerun this script."

if ! command -v bun >/dev/null 2>&1; then
	say "Installing Bun"
	curl -fsSL https://bun.sh/install | bash
	if [[ -x "$HOME/.bun/bin/bun" ]]; then
		export PATH="$HOME/.bun/bin:$PATH"
	fi
fi
command -v bun >/dev/null 2>&1 || fail "Bun was installed but is not available. Open a new terminal or run: source ~/.bashrc"

if ! command -v node >/dev/null 2>&1; then
	fail "Node.js >=22 is required. Install Node.js 22 or newer, then rerun this script."
fi
node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
(( node_major >= 22 )) || fail "Node.js >=22 is required; found $(node --version). Install Node.js 22 or newer."

command -v code >/dev/null 2>&1 || printf 'Note: VS Code CLI (code) was not found. Install VS Code to launch the extension after setup.\n'

if ! command -v gitleaks >/dev/null 2>&1; then
	install_dir="$HOME/.local/bin"
	mkdir -p "$install_dir"
	if [[ -x "$HOME/dev/gitleaks/gitleaks" ]]; then
		say "Installing the locally built gitleaks binary"
		install -m 0755 "$HOME/dev/gitleaks/gitleaks" "$install_dir/gitleaks"
	else
		command -v tar >/dev/null 2>&1 || fail "tar is required to install gitleaks. Install tar and rerun this script."
		case "$(uname -s)/$(uname -m)" in
			Linux/x86_64|Linux/aarch64|Darwin/x86_64|Darwin/arm64) ;;
			*) fail "Automatic gitleaks installation supports Linux x86_64/aarch64 and macOS x86_64/arm64; install gitleaks manually on this platform." ;;
		esac

		say "Installing gitleaks from its latest release"
		gitleaks_version="$(curl -fsSL https://api.github.com/repos/gitleaks/gitleaks/releases/latest | node -e '
let body = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", chunk => body += chunk);
process.stdin.on("end", () => {
	const release = JSON.parse(body);
	if (!release.tag_name) process.exit(1);
	process.stdout.write(release.tag_name.replace(/^v/, ""));
});
')" || fail "Could not determine the latest gitleaks release. Install gitleaks manually and rerun this script."
		case "$(uname -s)/$(uname -m)" in
			Linux/x86_64) gitleaks_platform="linux_x64" ;;
			Linux/aarch64) gitleaks_platform="linux_arm64" ;;
			Darwin/x86_64) gitleaks_platform="darwin_x64" ;;
			Darwin/arm64) gitleaks_platform="darwin_arm64" ;;
		esac
		gitleaks_archive="gitleaks_${gitleaks_version}_${gitleaks_platform}.tar.gz"
		gitleaks_tmp="$(mktemp -d)"
		trap 'rm -rf "$gitleaks_tmp"' EXIT
		curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${gitleaks_version}/${gitleaks_archive}" -o "$gitleaks_tmp/$gitleaks_archive"
		tar -xzf "$gitleaks_tmp/$gitleaks_archive" -C "$gitleaks_tmp" gitleaks
		install -m 0755 "$gitleaks_tmp/gitleaks" "$install_dir/gitleaks"
		rm -rf "$gitleaks_tmp"
		trap - EXIT
	fi
	export PATH="$install_dir:$PATH"
	add_path_to_profile "$HOME/.bashrc"
	if [[ -n "${ZSH_VERSION:-}" || -f "$HOME/.zshrc" ]]; then
		add_path_to_profile "$HOME/.zshrc"
	fi
fi

if [[ -f bun.lock ]]; then
	say "Installing repository dependencies"
	bun install
else
	fail "Run this script from a Cline checkout containing bun.lock."
fi

say "Building Cline SDK packages"
bun run build:sdk

say "Building the VS Code extension webview"
cd "$ROOT_DIR/apps/vscode"
bun run build:webview

say "Building the VS Code extension host bundle"
bun esbuild.mjs

if [[ -x "$HOME/.bun/bin/bun" || -x "$HOME/.local/bin/gitleaks" ]]; then
	cat <<'EOF'

To make newly installed tools available in this terminal, run:
  source ~/.bashrc
Then restart VS Code so its Git hooks inherit the updated PATH.
EOF
fi

cat <<'EOF'

Setup complete. Launch the extension development host from the repository root with:
  code --extensionDevelopmentPath="$PWD/apps/vscode" "$PWD"

On a Linux desktop session that needs an explicit display, prefix the command with:
  DISPLAY=:1
EOF
