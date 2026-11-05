# Template for Casks/tacho.rb in gogy717/homebrew-tap. Every release sets version and sha256 there;
# the sha256 below is a placeholder, the real one is the zip's from that release.
cask "tacho" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/gogy717/tacho/releases/download/v#{version}/Tacho-#{version}.zip"
  name "Tacho"
  desc "Menu bar token meter for AI coding CLIs"
  homepage "https://github.com/gogy717/tacho"

  depends_on macos: :sonoma

  app "Tacho.app"

  uninstall quit: "io.github.gogy717.tacho"

  zap trash: [
    "~/Library/Application Support/Tacho",
    "~/Library/Preferences/io.github.gogy717.tacho.plist",
  ]

  caveats <<~EOS
    Tacho is unsigned: it has only an ad-hoc signature and is not notarized, so macOS
    refuses to open it while it is quarantined. Clear the flag once:
      xattr -dr com.apple.quarantine #{appdir}/Tacho.app
  EOS
end
