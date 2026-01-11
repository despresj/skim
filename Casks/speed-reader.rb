cask "speed-reader" do
  version :latest
  sha256 :no_check

  url "https://github.com/despresj/speed-reader/releases/latest/download/SpeedReader.zip"
  name "Speed Reader"
  desc "macOS speed-reading app"
  homepage "https://github.com/despresj/speed-reader"

  depends_on macos: ">= :sonoma"

  app "Speed Reader.app"

  zap trash: [
    "~/Library/Application Support/SpeedReader",
    "~/Library/Caches/com.quickspec.speedreader",
    "~/Library/Preferences/com.quickspec.speedreader.plist",
    "~/Library/Saved Application State/com.quickspec.speedreader.savedState",
  ]
end

