# This repository is its own Homebrew tap:
#   brew tap shklyarovalera/agent-scope https://github.com/ShklyaroValera/agent-scope
#   brew install --cask shklyarovalera/agent-scope/agentscope
# scripts/release.sh fills in version and sha256; .github/workflows/release.yml runs it on a v* tag.
cask "agentscope" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256"

  url "https://github.com/ShklyaroValera/agent-scope/releases/download/v#{version}/AgentScope-#{version}.zip"
  name "AgentScope"
  desc "Menu bar app showing every running AI coding agent"
  homepage "https://github.com/ShklyaroValera/agent-scope"

  depends_on macos: :sonoma

  app "AgentScope.app"
  binary "#{appdir}/AgentScope.app/Contents/Helpers/agentscope"

  # Releases are ad-hoc signed until a Developer ID is set up; without this Gatekeeper refuses to
  # open the quarantined app. Drop this block once releases are signed and notarized.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/AgentScope.app"]
  end

  # Take AgentScope's hooks out of the agents' configs before the app goes away.
  uninstall quit:   "io.github.shklyarovalera.agentscope",
            script: {
              executable: "#{appdir}/AgentScope.app/Contents/Helpers/agentscope",
              args:       ["uninstall"],
              sudo:       false,
            }

  zap trash: [
    "~/Library/Application Support/AgentScope",
    "~/Library/Preferences/io.github.shklyarovalera.agentscope.plist",
  ]

  caveats <<~EOS
    Connect your agents (Claude Code, Codex, Copilot CLI):
      agentscope setup
    `brew uninstall` removes the hooks again (same as `agentscope uninstall`).
  EOS
end
