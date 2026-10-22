# Template for the Homebrew tap (github.com/ShklyaroValera/homebrew-tap → Casks/agentscope.rb).
# scripts/release.sh fills in version and sha256.
cask "agentscope" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256"

  url "https://github.com/ShklyaroValera/agent-scope/releases/download/v#{version}/AgentScope-#{version}.zip"
  name "AgentScope"
  desc "Menu bar app showing every AI coding agent running on your Mac"
  homepage "https://github.com/ShklyaroValera/agent-scope"

  depends_on macos: ">= :sonoma"

  app "AgentScope.app"
  binary "#{appdir}/AgentScope.app/Contents/Helpers/agentscope"

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
