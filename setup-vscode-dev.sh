#!/usr/bin/env bash
set -euo pipefail

# Prepare and install this checkout's VS Code extension. The intended local model
# is a Qwen server at 192.168.1.14 with an OpenAI-compatible API.
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"
QWEN_HOST="${CLINE_QWEN_HOST:-192.168.1.14}"
QWEN_API_PORTS="${CLINE_QWEN_API_PORTS:-8000,8080,1234,11434,9800}"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
tools_installed=0

add_path_to_profile() {
	local profile="$1"
	local entry='export PATH="$HOME/.local/bin:$PATH"'
	[[ -f "$profile" ]] || touch "$profile"
	if ! grep -Fq "$entry" "$profile"; then
		printf '\n# User-installed command line tools\n%s\n' "$entry" >> "$profile"
	fi
}

check_qwen_endpoint() {
	local found_api=0
	local port status raw_response
	local -a ports
	IFS=',' read -r -a ports <<< "$QWEN_API_PORTS"

	printf 'Checking for an OpenAI-compatible Qwen API at %s (ports: %s)\n' "$QWEN_HOST" "$QWEN_API_PORTS"
	for port in "${ports[@]}"; do
		status="$(curl --silent --connect-timeout 2 --max-time 4 -o /dev/null -w '%{http_code}' "http://${QWEN_HOST}:${port}/v1/models" 2>/dev/null || true)"
		if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
			printf 'API responded with HTTP %s: http://%s:%s/v1\n' "$status" "$QWEN_HOST" "$port"
			found_api=1
		elif [[ "$status" == 401 || "$status" == 403 ]]; then
			printf 'API found at http://%s:%s/v1 but it requires authentication (HTTP %s).\n' "$QWEN_HOST" "$port" "$status"
			found_api=1
		elif [[ "$status" == 404 ]]; then
			printf 'HTTP service found on port %s, but /v1/models returned 404.\n' "$port"
		elif [[ "$status" =~ ^[45][0-9][0-9]$ ]]; then
			printf 'HTTP service found on port %s, but /v1/models returned HTTP %s.\n' "$port" "$status"
		else
			raw_response="$(curl --silent --connect-timeout 1 --max-time 2 --http0.9 "http://${QWEN_HOST}:${port}/v1/models" 2>/dev/null || true)"
			if [[ -n "$raw_response" ]]; then
				printf 'Port %s responds with a non-HTTP service, not an OpenAI-compatible API.\n' "$port"
			fi
		fi
	done

	if (( ! found_api )); then
		printf 'No OpenAI-compatible Qwen API was detected. Cline should use provider “OpenAI Compatible” with base URL http://%s:<API_PORT>/v1 once the model server is listening.\n' "$QWEN_HOST"
		printf 'For a nonstandard port, set CLINE_QWEN_API_PORTS (comma-separated) and rerun with --check-qwen.\n'
		return 1
	fi
}

if [[ "${1:-}" == "--check-qwen" ]]; then
	command -v curl >/dev/null 2>&1 || fail "curl is required for the Qwen endpoint check."
	check_qwen_endpoint
	exit $?
fi

command -v curl >/dev/null 2>&1 || fail "curl is required to install Bun. Install curl and rerun this script."

if ! command -v bun >/dev/null 2>&1; then
	say "Installing Bun"
	curl -fsSL https://bun.sh/install | bash
	tools_installed=1
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

command -v code >/dev/null 2>&1 || fail "VS Code CLI 'code' is required to install the extension. Install VS Code with its command-line launcher enabled, then rerun this script."

if ! command -v gitleaks >/dev/null 2>&1; then
	tools_installed=1
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

cd "$ROOT_DIR/apps/vscode"
extension_version="$(node -p 'require("./package.json").version')"
vsix_path="/tmp/cline-aldenpark-${extension_version}.vsix"

say "Packaging Cline (aldenpark) as a VS Code extension"
bunx vsce package --no-dependencies --out "$vsix_path"

say "Installing or updating Cline (aldenpark) in the regular VS Code profile"
code --install-extension "$vsix_path" --force
check_qwen_endpoint || true

if (( tools_installed )); then
	cat <<'EOF'

To make newly installed tools available in this terminal, run:
  source ~/.bashrc
Then restart VS Code so its Git hooks inherit the updated PATH.
EOF
fi

cat <<'EOF'

Setup complete. Cline (aldenpark) is installed in your regular VS Code profile.
If VS Code was already open, reload the window to activate the updated build.
EOF
