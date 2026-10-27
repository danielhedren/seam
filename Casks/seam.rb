cask "seam" do
  version "0.4"
  sha256 "8b52ec8fa6eea23265692aac5113b97960c00d458be4db265355f6acc67160c6"

  url "https://github.com/danielhedren/seam/releases/download/v#{version}/Seam-#{version}.zip"
  name "Seam"
  desc "Diff viewer for reviewing git worktrees"
  homepage "https://github.com/danielhedren/seam"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Seam.app"
  binary "#{appdir}/Seam.app/Contents/Resources/seam"

  uninstall quit: "com.danielhedren.seam"

  zap trash: [
    "~/Library/Application Support/Seam",
    "~/Library/Preferences/com.danielhedren.seam.plist",
  ]

  caveats <<~EOS
    Seam isn't notarized. On first launch macOS blocks it: open System Settings ›
    Privacy & Security and choose Open Anyway.
  EOS
end
