cask "skim" do
  version :latest
  sha256 :no_check

  url "https://github.com/despresj/skim/releases/latest/download/Skim.zip"
  name "Skim"
  desc "macOS speed-reading app"
  homepage "https://github.com/despresj/skim"

  depends_on macos: ">= :sonoma"

  app "Skim.app"

  zap trash: [
    "~/Library/Application Support/Skim",
    "~/Library/Caches/com.quickspec.skim",
    "~/Library/Preferences/com.quickspec.skim.plist",
    "~/Library/Saved Application State/com.quickspec.skim.savedState",
  ]
end
