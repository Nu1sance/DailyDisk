# Run with HOMEBREW_DEVELOPER=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1
# brew ruby Scripts/Homebrew/test-contract.rb.
# Synthetic fixtures only: no downloads, receipts, launchd or production app writes.
require "cask/cask"
require "cask/installer"
require "tmpdir"
require "json"

results = []
def assert_contract(condition, message)
  raise message unless condition
end

Dir.mktmpdir("dailydisk-brew-contract-") do |directory|
  root = Pathname(directory)
  make_cask = lambda do |target_version, receipt, short_version, build|
    cask = Cask::Cask.new("dailydisk-contract") do
      version target_version
      sha256 "0" * 64
      url "https://example.invalid/dailydisk.zip"
      homepage "https://example.invalid/"
      auto_updates true
      app "Fixture.app"
    end
    app = root/"target/Fixture.app"
    plist = app/"Contents/Info.plist"
    plist.dirname.mkpath
    plist.write <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict>
      <key>CFBundleShortVersionString</key><string>#{short_version}</string>
      <key>CFBundleVersion</key><string>#{build}</string>
      </dict></plist>
    XML
    cask.artifacts.grep(Cask::Artifact::App).first.define_singleton_method(:target) { app }
    cask.define_singleton_method(:installed_version) { receipt }
    cask
  end
  matrix = [
    ["older marketing version", "0.2.2,17", "0.2.1,16", "0.2.1", "16", {}, true],
    ["Sparkle already updated", "0.2.2,17", "0.2.1,16", "0.2.2", "17", {}, false],
    ["Sparkle ahead of tap", "0.2.2,17", "0.2.1,16", "0.2.3", "18", {}, false],
    ["same marketing version newer build is missed", "0.2.1,17", "0.2.1,16", "0.2.1", "16", {}, false],
    ["greedy uses old receipt even when app ahead", "0.2.2,17", "0.2.1,16", "0.2.3", "18", {greedy: true}, true],
    ["greedy auto updates also uses receipt", "0.2.2,17", "0.2.1,16", "0.2.3", "18", {greedy_auto_updates: true}, true],
    ["equal receipt can hide a downgraded app", "0.2.2,17", "0.2.2,17", "0.2.1", "16", {}, false],
  ]
  matrix.each do |name, version, receipt, short, build, flags, expected|
    cask = make_cask.call(version, receipt, short, build)
    actual = !cask.outdated_version(**flags).nil?
    assert_contract(actual == expected, "#{name}: #{actual} != #{expected}")
    results << {scenario: name, outdated: actual}
  end
  cask = make_cask.call("0.2.2,17", "0.2.1,16", "0.2.1", "16")
  (cask.artifacts.grep(Cask::Artifact::App).first.target/"Contents/Info.plist").unlink
  assert_contract(cask.outdated_version.nil?, "missing plist policy changed")
  results << {scenario: "missing plist is not a health guarantee", outdated: false}
  installer_only = Cask::Cask.new("dailydisk-installer-contract") do
    version "0.2.2,17"
    sha256 "0" * 64
    url "https://example.invalid/dailydisk.zip"
    auto_updates true
    installer script: "/usr/bin/true"
  end
  installer_only.define_singleton_method(:installed_version) { "0.2.1,16" }
  assert_contract(installer_only.send(:bundle_version).nil?, "installer-only bundle discovery changed")
  assert_contract(installer_only.outdated_version.nil?, "installer-only outdated behavior changed")
  results << {scenario: "installer-only loses bundle version discovery", outdated: false}
end
# Exercise Homebrew's real installer orchestration. Artifact mutation is replaced
# by observers: no production filesystem operation is performed.
lifecycle = []
Dir.mktmpdir("dailydisk-brew-lifecycle-") do |directory|
  root = Pathname(directory)
  events = []
  lock = root/"lease"
  held_during_app = nil
  build_installer = lambda do |label, fail_install|
    cask = Cask::Cask.new("dailydisk-contract") do
      version label == "old" ? "0.2.1,16" : "0.2.2,17"
      sha256 "0" * 64
      url "https://example.invalid/dailydisk.zip"
      homepage "https://example.invalid/"
      app "Fixture.app"
      preflight_steps []
      postflight_steps []
      uninstall_preflight_steps []
      uninstall_postflight_steps []
    end
    cask.artifacts.grep(Cask::Artifact::AbstractInstallSteps).each do |flight|
      flight.define_singleton_method(:run_steps) do |_command, phase: :install|
        key = self.class.dsl_key.to_s.delete_suffix("_steps")
        events << "#{label}:#{key}:#{phase}"
        File.open(lock, File::RDWR | File::CREAT, 0o600) do |lease|
          raise "lease busy" unless lease.flock(File::LOCK_EX | File::LOCK_NB)
        end
      end
    end
    app = cask.artifacts.grep(Cask::Artifact::App).first
    app.define_singleton_method(:install_phase) do |**_kwargs|
      events << "#{label}:app_install"
      File.open(lock, File::RDWR | File::CREAT, 0o600) do |probe|
        held_during_app = !probe.flock(File::LOCK_EX | File::LOCK_NB)
      end
      raise "synthetic replacement failure" if fail_install
    end
    app.define_singleton_method(:uninstall_phase) do |**_kwargs|
      events << "#{label}:app_remove"
    end
    installer = Cask::Installer.new(cask)
    # Metadata operations are deliberately isolated from the real Caskroom.
    %i[save_config_file save_download_sha purge_versioned_files backup restore_backup].each do |method|
      installer.define_singleton_method(method) { events << "#{label}:#{method}" }
    end
    [cask, installer]
  end
  old, old_installer = build_installer.call("old", false)
  new_cask, new_installer = build_installer.call("new", true)
  old_installer.start_upgrade(successor: new_cask)
  begin
    new_installer.install_artifacts(predecessor: old)
    raise "expected failure was absent"
  rescue => error
    raise unless error.message == "synthetic replacement failure"
  end
  old_installer.revert_upgrade(predecessor: new_cask)
  assert_contract(events.index("old:app_remove") < events.index("new:preflight:install"), "upgrade removal order changed")
  assert_contract(!events.include?("new:postflight:install"), "failed install unexpectedly ran postflight")
  assert_contract(events.include?("old:app_install"), "rollback did not restore old app")
  assert_contract(held_during_app == false, "short preflight lease unexpectedly survived")
  lifecycle << {scenario: "failed upgrade and rollback", events: events.dup, preflight_lease_covers_app: held_during_app}
  events.clear
  old_installer.uninstall_artifacts
  assert_contract(events.index("old:uninstall_preflight:install") < events.index("old:app_remove"), "uninstall ordering changed")
  lifecycle << {scenario: "uninstall", events: events.dup}
end
sandbox_result = nil
Dir.mktmpdir("dailydisk-brew-sandbox-") do |directory|
  root = Pathname(directory)
  helper = root/"lease.rb"
  lock = root/"lease"
  trace = root/"trace"
  helper.write <<~RUBY
    File.open(ARGV[0], File::RDWR | File::CREAT, 0600) do |lease|
      abort "lock busy" unless lease.flock(File::LOCK_EX | File::LOCK_NB)
      File.write(ARGV[1], Process.pid.to_s)
    end
  RUBY
  cask = Cask::Cask.new("dailydisk-contract") do
    version "0.2.1,16"
    sha256 "0" * 64
    url "https://example.invalid/dailydisk.zip"
    app "Fixture.app"
    preflight_steps do
      run "/usr/bin/ruby", args: [helper.to_s, lock.to_s, trace.to_s]
    end
  end
  cask.config = Cask::Config.new(explicit: {appdir: root/"target"})
  cask.define_singleton_method(:staged_path) { root }
  cask.define_singleton_method(:caskroom_path) { root }
  flight = cask.artifacts.grep(Cask::Artifact::PreflightSteps).first
  flight.install_phase
  acquired = File.open(lock, File::RDWR) { |probe| !!probe.flock(File::LOCK_EX | File::LOCK_NB) }
  assert_contract(acquired, "preflight child lease did not end at callback boundary")
  assert_contract(Integer(trace.read) != Process.pid, "flight helper unexpectedly ran in parent")
  sandbox_result = {separate_process: true, lease_released_before_app_artifact: acquired}
end
puts JSON.pretty_generate({homebrew: HOMEBREW_VERSION, version_matrix: results, lifecycle: lifecycle,
                           real_preflight: sandbox_result})
