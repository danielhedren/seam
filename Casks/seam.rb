cask "seam" do
  version "0.5"
  sha256 "52c93f0be21ae47f7689742261bae0bcfe6df869eb3579a133a164fc06d213bf"

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
