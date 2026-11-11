# frozen_string_literal: true

require_relative "support"
require_relative "codesign"
require_relative "release"
require_relative "formula"
require "shellwords"

# Crystal-specific project configuration and tasks. Crystal::Project holds all
# the data (project name, components, directories, current-host profiles) and knows how to define
# its tasks: the Crystal build/test tasks directly, and release/formula by
# calling the generic factories. Rake loads every rakelib/*.rake automatically,
# so this file defines the tasks itself at the bottom; the .rb files beside it
# are libraries and task factories with no tasks of their own.
module Crystal
  # The shards manifest — the single source of truth for the version, and for
  # everything else the shards format defines (name, targets, dependencies).
  SHARD_PATH = "shard.yml"

  # The project file, whose `crystal` key holds the build settings the shards
  # format has no place for (profiles, static_libraries, identifier_prefix).
  PROJECT_PATH = ".project.yaml"

  # The build modes, each with its own profile list in the project file.
  MODES = %w[debug release].freeze

  # The project-file key whose profiles are built in every mode, so a profile
  # that does not differ between modes is listed once.
  COMMON_PROFILES = "common"

  # Where macOS keeps the libraries every Mac is guaranteed to have. A binary
  # linking only these runs on any same-arch Mac; a library from anywhere else
  # (Homebrew, /usr/local, an @rpath) has to travel with it.
  SYSTEM_LIBRARY_PREFIXES = ["/usr/lib/", "/System/Library/"].freeze

  # Parses and confines user-supplied focused spec paths to the repository.
  module FocusedSpecPaths
    module_function

    def parse(input, repository_root:)
      paths = Shellwords.split(input.to_s)
      raise ArgumentError, "spec:focus requires at least one spec path" if paths.empty?

      spec_root = File.realpath(File.join(repository_root, "spec"))
      paths.each do |path|
        validate_path!(path, repository_root: repository_root, spec_root: spec_root)
      end
      paths
    end

    def validate_path!(path, repository_root:, spec_root:)
      raise ArgumentError, "Focused spec path must be under spec/: #{path}" if path.start_with?("-") || !path.start_with?("spec/")

      resolved = File.realpath(File.expand_path(path, repository_root))
      return if resolved.start_with?("#{spec_root}#{File::SEPARATOR}")

      raise ArgumentError, "Focused spec path escapes spec/: #{path}"
    rescue Errno::ENOENT
      raise ArgumentError, "Focused spec path does not exist: #{path}"
    end
  end

  # A build target: a shards target name plus the component name (target with the
  # project prefix stripped), which also names its spec/test directories, and
  # the component's own linker argument templates from the project file
  # (`crystal.components.<component>.linker.arguments` — see Project's doc
  # comment for the placeholders).
  #
  # Every component is a sibling — there is no privileged one whose specs live at
  # the top level. That special case used to exist, inferred from `name ==
  # target`, and it held only while one target happened to be spelled exactly
  # like the shard; a target rename would have silently pointed the top-level
  # suite at a directory that did not exist and enumerated nothing rather than
  # failing. One directory per component, unconditionally, has no such edge.
  Component = Data.define(:name, :target, :linker_arguments) do
    def spec_dir = "spec/#{name}"
    def test_dir = "test/#{name}"
  end

  # A build profile: the platform plus the libc/linkage that identify a build
  # variant. Its dir names the bin/ subdirectory (<ostype>-<arch>-<libc>-<linkage>);
  # Project appends the build mode when building.
  Profile = Data.define(:platform, :libc, :linkage) do
    # Parse a profile dir string (<ostype>-<arch>-<libc>-<linkage>) back into a Profile.
    def self.parse(dir)
      ostype, arch, libc, linkage = dir.split("-")
      new(platform: Platform.new(ostype: ostype, arch: arch), libc: libc, linkage: linkage)
    end

    def dir = "#{platform.ostype}-#{platform.arch}-#{libc}-#{linkage}"

    # On macOS, Crystal auto-adds -fuse-ld=mold, which Apple's clang rejects.
    # Supplying our own -fuse-ld= disables that and forces Apple's ld; no-op elsewhere.
    def linker_args
      platform.ostype == "darwin" ? "-fuse-ld=/usr/bin/ld" : ""
    end

    def link_flags
      linker_args.empty? ? "" : " --link-flags=#{linker_args}"
    end
  end

  # All Crystal-specific project data, with derived build paths and task
  # definitions. Includes Rake::DSL so its methods (and the task action blocks,
  # which run with the instance as self) can call task/desc/namespace/sh/etc.
  # +profiles+ maps each build mode to the profiles valid on the current host
  # (selected from the project file's `crystal.profiles` mapping by
  # Project.create), so a mode builds only the profiles listed under it.
  # Linker arguments are per component: the project file's
  # `crystal.components.<component>.linker.arguments` lists additional linker
  # argument templates for that component's compiles, with `{root}` expanding
  # to the absolute project root and `{ostype}`/`{arch}` to the build
  # profile's platform. A project whose binary links a vendored native archive points a
  # `-L{root}/…` entry at it and hooks whatever builds the archive onto the
  # `prepare` task from its Rakefile; this file stays ignorant of what is
  # being linked.
  Project = Data.define(
    :name, :components, :bin_dir, :dist_dir, :coverage_dir, :src_dir, :profiles,
    :static_libraries, :identifier_prefix, :allow_jit
  ) do
    include Rake::DSL

    # The profiles this host builds in +mode+.
    def profiles_for(mode) = profiles.fetch(mode, [])

    # The preferred profile for the tools that always build in debug (spec,
    # cover, run), or nil if none apply. Prefers dynamic over static, and musl
    # over glibc.
    def default_profile
      profiles_for("debug").min_by { |profile| [profile.linkage == "dynamic" ? 0 : 1, profile.libc == "musl" ? 0 : 1] }
    end

    # The bin/ subdirectory for a build profile in the given mode (mode appended last).
    def bin_dir_for(profile:, mode:)
      File.join(bin_dir, "#{profile.dir}-#{mode}")
    end

    # The code-signing identifier for a component:
    # <identifier_prefix>.<project name>.<component>, or nil when the project
    # file sets no prefix (codesign then derives one from the file name, which
    # no code-signing requirement can pin). Reverse-DNS by convention, so a
    # peer requirement can name the binary rather than its file name.
    #
    # Built from the project name and the component rather than from the target,
    # so the identifier stays a property of what the binary *is* rather than of
    # what the target happens to be called. It also keeps the identifiers
    # mutually non-prefixing: `<prefix>.<name>` derived from bare target names
    # can end up a proper prefix of a sibling (`…my-tool` vs `…my-tool-run`),
    # which is a hazard for any requirement that ever matched on prefix rather
    # than equality.
    def signing_identifier(component:)
      identifier_prefix && "#{identifier_prefix}.#{name}.#{component}"
    end

    def formula_path = "deploy/homebrew/#{name}.rb"

    # Each component owns exactly its own directory, so there is nothing to
    # subtract: no component's tree contains another's.
    def spec_files(component:)
      Dir[File.join(component.spec_dir, "**", "*_spec.cr")].sort
    end

    # The complete linker arguments for a profile: the profile's own, plus
    # +component+'s `crystal.components.<component>.linker.arguments` from
    # the project file with `{root}` (the absolute project root — `shards
    # build` does not resolve relative `-L` paths) and `{ostype}`/`{arch}`
    # (the build profile's platform) expanded. Without a component — a compile spanning
    # several, such as `spec:focus` — the union of every component's
    # arguments applies; a search path a compile does not need is inert.
    # Public because project-specific tasks in the Rakefile build Crystal
    # sources of their own and must link the same way the core tasks do.
    def combined_linker_args(profile:, component: nil)
      abort "no build profile configured for this host in #{PROJECT_PATH}" if profile.nil?

      templates = component ? component.linker_arguments : components.flat_map(&:linker_arguments).uniq
      expanded = templates.map do |argument|
        argument.gsub("{root}", Dir.pwd)
          .gsub("{ostype}", profile.platform.ostype)
          .gsub("{arch}", profile.platform.arch)
      end
      [profile.linker_args, *expanded].reject(&:empty?).join(" ")
    end

    def crystal_link_flags(profile:, component: nil)
      %( --link-flags="#{combined_linker_args(profile: profile, component: component)}")
    end

    # Define all tasks for this project: the aggregates and per-component
    # namespaces directly, and release/formula via the generic factories.
    def define_tasks
      CLEAN.include("#{bin_dir}/*", "#{dist_dir}/*", coverage_dir)
      CLOBBER.include(bin_dir, "lib", ".shards")

      component_names = components.map(&:name)

      # The hook every compiling task depends on. Empty here; a project whose
      # `crystal.linker_args` point at a built artifact (a vendored native
      # archive, say) attaches its build from the Rakefile:
      # `task "prepare" => "tree_sitter:build"`.
      desc "Prepare compile prerequisites (hook project tasks here)"
      task "prepare"

      define_build_tasks

      # Invokes the per-component tasks rather than depending on them, because a
      # Rake prerequisite cannot be passed an argument. Quote the whole thing in
      # zsh — `rake 'spec[redacts]'` — or the brackets glob.
      desc "Run unit tests (optional argument: example pattern)"
      task "spec", [:pattern] do |_task, args|
        component_names.each do |component|
          Rake::Task["#{component}:spec"].invoke(args[:pattern])
        end
      end

      namespace "spec" do
        desc "Run focused Crystal spec paths"
        task "focus", [:paths] => ["prepare"] do |_task, args|
          paths = FocusedSpecPaths.parse(args[:paths], repository_root: Dir.pwd)
          sh "crystal", "spec", *paths, "-Dspec",
             "--link-flags=#{combined_linker_args(profile: default_profile)}"
        end
      end

      define_dist_tasks

      desc "Run integration tests"
      task "test" => component_names.map { |component| "#{component}:test" }

      desc "Run unit tests with coverage"
      task "cover" => component_names.map { |component| "#{component}:cover" }

      define_lint_tasks

      desc "Install Crystal dependencies"
      task "deps" do
        sh "shards install"
      end

      desc "Set up the project (install dependencies)"
      task "setup" => "deps"

      desc "List the build profiles supported on this host, per mode"
      task "profiles" do
        MODES.each do |mode|
          puts "#{mode}:"
          profiles_for(mode).each { |profile| puts "  #{profile.dir}" }
        end
      end

      components.each { |component| define_component_tasks(component: component) }
      define_packaging_tasks
      define_notary_setup_task
    end

    # Release and Homebrew-formula tasks, via the generic factories. The version
    # lives in shard.yml (the single source of truth), so both tasks read it
    # through the same lambda.
    def define_packaging_tasks
      read_version = -> { File.read(SHARD_PATH)[%r{^version:\s*(\S+)}, 1] }

      define_release_task(
        name: "release",
        read_version: read_version,
        write_version: lambda do |version|
          raw = File.read(SHARD_PATH)
          abort "Could not find version field in #{SHARD_PATH}" unless raw.match?(%r{^version:.*$})
          File.write(SHARD_PATH, raw.sub(%r{^version:.*$}, "version: #{version}"))
        end,
        version_files: [SHARD_PATH]
      )

      define_formula_task(name: "homebrew:formula:update", formula_path: formula_path,
                          binary_prefix: name, read_version: read_version,
                          assets_dir: dist_dir)
    end

    # `lint` is a group task with no action of its own: each linter defines its
    # own subtask and joins the group as a prerequisite, so adding a linter
    # never edits this file — `rakelib/github.rake` does exactly that for the
    # workflows.
    def define_lint_tasks
      desc "Run every linter"
      task "lint" => "lint:crystal"

      namespace "lint" do
        desc "Run Ameba over the Crystal sources"
        task "crystal" do
          binary = "lib/ameba/bin/ameba"
          # An ameba pinned to a commit may ship no postinstall, so a fresh
          # `shards install` leaves only sources behind — build the linter from
          # the installed shard on first use (and again after any reinstall,
          # which removes the whole lib/ameba tree).
          sh "crystal", "build", "lib/ameba/src/cli.cr", "-o", binary, "--release" unless File.executable?(binary)
          cmd = binary
          cmd += " --no-color" if no_color?
          sh cmd
        end
      end
    end

    # Release-asset packaging, one archive per profile this host has built.
    def define_dist_tasks
      namespace "dist" do
        desc "Package every built release profile into #{dist_dir}/"
        task "package" do
          archives = package_release_profiles
          abort "no release build under #{bin_dir}/; run `rake build:release` first" if archives.empty?

          archives.each { |archive| puts archive }
        end
      end
    end

    # Define the per-component namespace (build/spec/test/cover/run).
    def define_component_tasks(component:)
      target = component.target

      namespace component.name do
        desc "Run unit tests for #{target} (optional argument: example pattern)"
        task "spec", [:pattern] => ["prepare"] do |_task, args|
          link = combined_linker_args(profile: default_profile, component: component)
          command = ["crystal", "spec", *spec_files(component: component), "-Dspec",
                     "--link-flags=#{link}",]
          # Matches `<component>:test`'s `--example`: a substring of the full
          # nested example name, not a path. `spec:focus` is the path-shaped
          # filter, and the two compose badly enough to keep separate — this one
          # still compiles every spec file in the component and filters at run
          # time, so it narrows output, not build time.
          command += ["--example", args[:pattern]] if args[:pattern]
          sh(*command)
        end

        desc "Run integration tests for #{target} (optional argument: test pattern)"
        task "test", [:pattern] do |_, args|
          unless File.directory?(component.test_dir)
            puts "#{target}: no integration tests (#{component.test_dir}/ does not exist)"
            next
          end

          cmd = "bundle exec rspec --format documentation --require=./test/spec_helper.rb"
          cmd += " --example '#{args[:pattern]}'" if args[:pattern]
          cmd += " #{component.test_dir}"
          sh cmd
        end

        desc "Run unit tests with coverage for #{target}"
        task "cover" => ["prepare"] do
          bin = bin_dir_for(profile: default_profile, mode: "debug")
          mkdir_p bin
          mkdir_p ".work"

          runner = ".work/run_#{component.name}_specs.cr"
          requires = spec_files(component: component).map do |path|
            %(require "../#{path}")
          end
          File.write(runner, "#{requires.join("\n")}\n")

          spec_binary = File.join(bin, "#{target}-specs")
          link = crystal_link_flags(profile: default_profile, component: component)
          sh "crystal build #{runner} --output #{spec_binary} --debug#{link}"

          coverage_output = File.join(coverage_dir, component.name)
          mkdir_p coverage_output
          sh "kcov --clean --include-path=./#{src_dir} #{coverage_output} #{spec_binary}"
        end

        desc "Run the application in debug mode"
        task "run" => ["prepare"] do
          bin = bin_dir_for(profile: default_profile, mode: "debug")
          link = crystal_link_flags(profile: default_profile, component: component)
          sh "shards run #{target} --output=#{bin}/#{target} --debug#{link}"
        end
      end
    end

    # Project-level build tasks: build:<mode>:<profile> for each profile that
    # mode builds, build:<mode> to build them all, `build` for both modes, and
    # a `debug` shortcut for the preferred debug profile. Linkage follows each
    # profile.
    def define_build_tasks
      namespace "build" do
        MODES.each do |mode|
          mode_profiles = profiles_for(mode)

          namespace mode do
            mode_profiles.each do |profile|
              desc "Build all targets for #{profile.dir} (#{mode})"
              task(profile.dir => "prepare") { build_profile(profile: profile, mode: mode) }
            end
          end

          desc "Build every #{mode} profile for this host"
          task mode => mode_profiles.map { |profile| "build:#{mode}:#{profile.dir}" }
        end
      end

      desc "Build every host profile (debug and release)"
      task "build" => MODES.map { |mode| "build:#{mode}" }

      desc "Build the preferred debug profile for this host"
      task("debug" => "prepare") { build_profile(profile: default_profile, mode: "debug") }
    end

    private

    # One archive per release profile already built for this host, so a matrix
    # job that built one profile packages exactly that one and nothing else.
    # Profiles with no build directory are skipped rather than failing: a CI
    # runner only ever builds the profile matching its own arch.
    def package_release_profiles
      mkdir_p dist_dir
      profiles_for("release").filter_map do |profile|
        bin = bin_dir_for(profile: profile, mode: "release")
        next unless Dir.exist?(bin)

        package_profile(profile: profile, bin: bin)
      end
    end

    # `<name>-<profile>.tar.gz`, holding every component's binary at the
    # archive root — one asset per platform rather than one per binary, since a
    # multi-target project's binaries are typically useless apart.
    #
    # The members are named explicitly rather than globbed, so a build
    # directory's own scratch (`static-libs`, `.dwarf` companions) can never
    # end up in a release asset, and a missing binary fails here instead of
    # shipping an incomplete archive.
    def package_profile(profile:, bin:)
      targets = components.map(&:target)
      missing = targets.reject { |target| File.file?(File.join(bin, target)) }
      abort "#{bin}/ is missing #{missing.join(", ")}; run `rake build:release` first" unless missing.empty?

      archive = File.join(dist_dir, "#{name}-#{profile.dir}.tar.gz")
      rm_f archive
      # COPYFILE_DISABLE: bsdtar otherwise stores an `._name` AppleDouble
      # member for every file carrying extended attributes, which each consumer
      # then has to know to ignore.
      sh({ "COPYFILE_DISABLE" => "1" }, "tar", "--create", "--gzip",
         "--file", archive, "--directory", bin, *targets)
      archive
    end

    # Build every component for a profile in the given mode.
    def build_profile(profile:, mode:)
      abort "no build profile configured for this host in #{PROJECT_PATH}" if profile.nil?
      # Fail fast on a missing Developer ID before a slow release build.
      codesign_identity(release: true) if mode == "release" && profile.platform.ostype == "darwin"
      components.each { |component| build_target(component: component, mode: mode, profile: profile) }
    end

    # Build one component: assemble the shards command, verify the linkage,
    # sign, notarize (release), and symlink the convenience path. A macOS
    # `system-static` build links the Homebrew deps statically; everything
    # else links as the profile dictates.
    def build_target(component:, mode:, profile:)
      target = component.target
      bin = bin_dir_for(profile: profile, mode: mode)
      mkdir_p bin
      output = "#{bin}/#{target}"
      # macOS cannot fully static-link (no static libSystem); a `system-static`
      # profile instead static-links the Homebrew deps in static_libraries and
      # leaves the OS libraries dynamic, so the binary matches its profile dir in
      # every mode.
      deps_static = profile.platform.ostype == "darwin" && profile.linkage == "static"
      cmd = "shards build #{target} --output=#{output} --#{mode}"
      cmd += " --static" if profile.linkage == "static" && profile.libc != "system"
      cmd += link_flags_for(profile: profile, deps_static: deps_static, bin: bin,
                            component: component)
      sh cmd
      assert_only_system_dylibs(output) if deps_static
      # Without JIT the hardened binary needs no entitlements at all.
      codesign_binary(path: output, release: mode == "release",
                      identifier: signing_identifier(component: component.name),
                      entitlements: allow_jit ? nil : false)
      notarize_binary(path: output) if mode == "release"
      ln_sf File.join(File.basename(bin), target), File.join(bin_dir, target)
    end

    # The `--link-flags` argument for a build: the combined linker args, plus
    # (on a macOS deps-static build) a search path holding only the static
    # archives so `-l<name>` resolves to the `.a` before any Homebrew `.dylib`.
    def link_flags_for(profile:, deps_static:, bin:, component:)
      linker = combined_linker_args(profile: profile, component: component)
      if deps_static
        extra = "-L#{static_lib_dir(bin)} -Wl,-search_paths_first"
        linker = [linker, extra].reject(&:empty?).join(" ")
      end
      linker.empty? ? "" : %( --link-flags="#{linker}")
    end

    # A directory (beside the built binary) of symlinks to just the static
    # archives named in static_libraries — no `.dylib`, so the linker picks the
    # `.a`.
    def static_lib_dir(bin)
      dir = File.join(bin, "static-libs")
      rm_rf dir
      mkdir_p dir
      prefix = capture("brew", "--prefix").to_s.strip
      abort "static_libraries is set but `brew --prefix` failed" if prefix.empty?

      static_libraries.each do |name|
        archive = Dir["#{prefix}/opt/*/lib/lib#{name}.a", "#{prefix}/lib/lib#{name}.a"].first
        abort "static_libraries: no lib#{name}.a found under #{prefix}" unless archive
        ln_sf archive, File.join(dir, "lib#{name}.a")
      end

      File.expand_path(dir)
    end

    # The dynamic libraries a Mach-O binary links, per `otool -L`. Its first
    # line names the binary itself, and every dependency carries a trailing
    # version annotation; both are dropped.
    def linked_dylibs(binary)
      listed = capture("otool", "-L", binary)
      abort "otool -L #{binary} failed; cannot verify the linkage of #{binary}" if listed.nil?

      listed.lines.drop(1).map { |line| line.strip.sub(%r{\s+\(compatibility version .*\)\z}, "") }.reject(&:empty?)
    end

    # Fail a deps-static build that still links a library macOS does not ship —
    # a sign static_libraries is missing an entry. Such a binary runs here and
    # nowhere else, so this must stop the build rather than warn: it runs before
    # signing so a rejected binary is never signed or uploaded to Apple.
    def assert_only_system_dylibs(binary)
      external = linked_dylibs(binary).reject { |lib| lib.start_with?(*SYSTEM_LIBRARY_PREFIXES) }
      return if external.empty?

      abort <<~MESSAGE
        #{binary} links #{external.size} librar#{external.size == 1 ? "y" : "ies"} macOS does not ship, so it would not run on another Mac:
        #{external.map { |lib| "  #{lib}" }.join("\n")}
        Add each one's `-l` name to crystal.static_libraries in #{PROJECT_PATH}.
      MESSAGE
    end

    # The `crystal` section of the project file — the build settings that are
    # not part of the shards format. Aborts when the file or key is missing,
    # since the build profiles live there and nothing can be built without them.
    def self.build_config
      abort "#{PROJECT_PATH} is missing; it holds the `crystal` build settings" unless File.exist?(PROJECT_PATH)

      config = YAML.load_file(PROJECT_PATH)["crystal"]
      abort "#{PROJECT_PATH} has no `crystal` key holding the build settings" if config.nil?

      config
    end

    # Build a Project from shard.yml (name, targets), the project file's
    # `crystal` section (profiles, static libraries, signing prefix, and each
    # component's linker arguments), and the detected host.
    def self.create
      shard = YAML.load_file(SHARD_PATH)
      name = shard.fetch("name")
      config = build_config
      components = shard.fetch("targets").map do |target, _|
        component_name = target.delete_prefix("#{name}-")
        Component.new(name: component_name, target: target,
                      linker_arguments: config.dig("components", component_name, "linker", "arguments") || [])
      end

      host = ::Host.detect

      # Per mode, the common profiles plus that mode's own, keeping only the
      # ones valid on the current host.
      os_profiles = config.fetch("profiles").fetch(host.osname.to_s, {})
      common = os_profiles.fetch(COMMON_PROFILES, [])
      profiles = MODES.to_h do |mode|
        listed = (common | os_profiles.fetch(mode, [])).map { |p| Profile.parse(p) }
        [mode, listed.filter { |p| p.platform == host.platform }]
      end

      new(
        name: name,
        components: components,
        bin_dir: "bin",
        dist_dir: "dist",
        coverage_dir: "coverage",
        src_dir: "src",
        profiles: profiles,
        static_libraries: config.fetch("static_libraries", []),
        identifier_prefix: config["identifier_prefix"],
        # The allow-jit entitlement PCRE2's JIT needs under the hardened
        # runtime; a project whose binaries use no Regex sets it to false.
        allow_jit: config.fetch("allow_jit", true)
      )
    end
  end
end

# Exposed as a constant rather than a local, so the project's own tasks (the
# Rakefile loads before rakelib/*.rake, but its task *blocks* run later) can
# reach the same project object — its linker args, profiles and directories —
# instead of rebuilding one.
Crystal::PROJECT = Crystal::Project.create
Crystal::PROJECT.define_tasks
