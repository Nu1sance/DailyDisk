#!/usr/bin/env python3
"""Render the public tap Cask from an immutable, notarized release ZIP digest."""
import argparse
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument("--version", required=True)
parser.add_argument("--build", required=True)
parser.add_argument("--sha256", required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
    parser.error("version must be a stable x.y.z release")
if not re.fullmatch(r"[1-9][0-9]{0,8}", args.build):
    parser.error("build must be a canonical positive build number")
if not re.fullmatch(r"[0-9a-f]{64}", args.sha256):
    parser.error("sha256 must be the digest of the final stapled release archive")
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text('''# frozen_string_literal: true

cask "dailydisk" do
  version "%s,%s"
  sha256 "%s"

  url "https://github.com/Nu1sance/DailyDisk/releases/download/v#{version.csv.first}/DailyDisk-#{version.csv.first}-#{version.csv.second}-arm64.zip"
  name "DailyDisk"
  desc "Disk-growth monitor with daily reports"
  homepage "https://github.com/Nu1sance/DailyDisk"

  livecheck do
    url "https://nu1sance.github.io/DailyDisk/appcast.xml"
    strategy :sparkle
  end

  # Receipt-based upgrades are intentional. The signed installer checks the
  # actual app build and preserves newer Sparkle installations without downgrade.
  depends_on arch: :arm64
  depends_on macos: :sequoia

  # No app artifact: only the signed process may replace/remove the application,
  # while holding DailyDisk's installation and scan-admission leases.
  installer script: {
    executable: "DailyDisk.app/Contents/MacOS/DailyDisk",
    args:       ["--homebrew-install", appdir.to_s],
    sudo:       false,
  }

  uninstall script: {
    executable:   "#{staged_path}/DailyDisk.app/Contents/MacOS/DailyDisk",
    args:         ["--homebrew-uninstall", appdir.to_s],
    sudo:         false,
    must_succeed: true,
  }

  caveats <<~EOS
    Before replacing or removing an existing app, pause for manual replacement
    in DailyDisk Settings > General > Advanced, then quit DailyDisk.
    After replacement, open DailyDisk and choose Resume to restore daily checks.
    First installation needs no preparation. Uninstall keeps your local history.
    Use --appdir="$HOME/Applications" if /Applications is not writable.
  EOS
end
''' % (args.version, args.build, args.sha256))
