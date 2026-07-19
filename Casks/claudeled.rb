cask "claudeled" do
  version "0.1.0"
  sha256 :no_check # replaced with the real digest once a release is tagged

  url "https://github.com/odiumuniverse/claudeled/releases/download/v#{version}/claudeled-#{version}.zip"
  name "claudeled"
  desc "Caps Lock LED indicator for Claude Code"
  homepage "https://github.com/odiumuniverse/claudeled"

  # SMAppService ("Start at login") needs Ventura.
  depends_on macos: ">= :ventura"

  app "claudeled.app"

  # The app bundle is also the CLI, so this is a symlink rather than a second binary.
  binary "#{appdir}/claudeled.app/Contents/MacOS/claudeled"

  artifact "completions/_claudeled",
           target: "#{HOMEBREW_PREFIX}/share/zsh/site-functions/_claudeled"

  uninstall quit: "com.odiumuniverse.claudeled"

  zap trash: [
    "~/.config/claudeled",
  ]

  caveats <<~EOS
    claudeled installs its Claude Code hooks into ~/.claude/settings.json the
    first time you launch it, keeping a backup at settings.json.claudeled-backup.

    Before uninstalling, open the menu bar icon and untick
    "Claude Code hooks installed" so the hooks are removed cleanly.
  EOS
end
