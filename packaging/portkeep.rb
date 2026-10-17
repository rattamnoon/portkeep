# Homebrew cask template. Copy into a tap (e.g. rattamnoon/homebrew-tap) once a notarized
# release exists, and fill in version and sha256 from scripts/release.sh's output.
cask "portkeep" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE_SH"

  url "https://github.com/rattamnoon/portkeep/releases/download/v#{version}/Portkeep-#{version}.dmg"
  name "Portkeep"
  desc "Menu bar app that keeps SSH, AWS SSM, kubectl and other port forwards up"
  homepage "https://github.com/rattamnoon/portkeep"

  depends_on macos: ">= :sonoma"

  app "Portkeep.app"

  zap trash: [
    "~/Library/Application Support/Portkeep",
    "~/Library/Preferences/com.rattamnoon.portkeep.plist",
  ]
end
