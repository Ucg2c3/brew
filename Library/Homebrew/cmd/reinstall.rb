# typed: strict
# frozen_string_literal: true

require "abstract_command"
require "formula_installer"
require "development_tools"
require "messages"
require "install"
require "reinstall"
require "cleanup"
require "cask/utils"
require "cask/macos"
require "cask/reinstall"
require "upgrade"
require "api"

module Homebrew
  module Cmd
    class Reinstall < AbstractCommand
      cmd_args do
        description <<~EOS
          Uninstall and then reinstall a <formula> or <cask> using the same options it was
          originally installed with, plus any appended options specific to a <formula>.

          Unless `$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` is set, `brew upgrade` or `brew reinstall` will be run for
          outdated dependents and dependents with broken linkage, respectively.

          Unless `$HOMEBREW_NO_INSTALL_CLEANUP` is set, `brew cleanup` will then be run for the
          reinstalled formulae or, every 30 days, for all formulae.
        EOS
        switch "-d", "--debug",
               description: "If brewing fails, open an interactive debugging session with access to IRB " \
                            "or a shell inside the temporary build directory."
        switch "--display-times",
               env:         :display_install_times,
               description: "Print install times for each package at the end of the run."
        switch "-f", "--force",
               description: "Install without checking for previously installed keg-only or " \
                            "non-migrated versions."
        switch "-v", "--verbose",
               description: "Print the verification and post-install steps."
        [
          [:switch, "--formula", "--formulae", { description: "Treat all named arguments as formulae." }],
          [:switch, "-s", "--build-from-source", {
            description: "Compile <formula> from source even if a bottle is available.",
          }],
          [:switch, "-i", "--interactive", {
            description: "Download and patch <formula>, then open a shell. This allows the user to " \
                         "run `./configure --help` and otherwise determine how to turn the software " \
                         "package into a Homebrew package.",
          }],
          [:switch, "--force-bottle", {
            description: "Install from a bottle if it exists for the current or newest version of " \
                         "macOS, even if it would not normally be used for installation.",
          }],
          [:switch, "--keep-tmp", {
            description: "Retain the temporary files created during installation.",
          }],
          [:switch, "--debug-symbols", {
            depends_on:  "--build-from-source",
            description: "Generate debug symbols on build. Source will be retained in a cache directory.",
          }],
          [:switch, "-g", "--git", {
            description: "Create a Git repository, useful for creating patches to the software.",
          }],
          [:switch, "--ask", {
            description: "Ask for confirmation before downloading and upgrading formulae. " \
                         "Print bottles and dependencies download size, install and net install size.",
            env:         :ask,
          }],
        ].each do |args|
          options = args.pop
          send(*args, **options)
          conflicts "--cask", args.last
        end
        formula_options
        [
          [:switch, "--cask", "--casks", { description: "Treat all named arguments as casks." }],
          [:switch, "--[no-]binaries", {
            description: "Disable/enable linking of helper executables (default: enabled).",
            env:         :cask_opts_binaries,
          }],
          [:switch, "--require-sha",  {
            description: "Require all casks to have a checksum.",
            env:         :cask_opts_require_sha,
          }],
          [:switch, "--[no-]quarantine", {
            description: "Disable/enable quarantining of downloads (default: enabled).",
            env:         :cask_opts_quarantine,
          }],
          [:switch, "--adopt", {
            description: "Adopt existing artifacts in the destination that are identical to those being installed. " \
                         "Cannot be combined with `--force`.",
          }],
          [:switch, "--skip-cask-deps", {
            description: "Skip installing cask dependencies.",
          }],
          [:switch, "--zap", {
            description: "For use with `brew reinstall --cask`. Remove all files associated with a cask. " \
                         "*May remove files which are shared between applications.*",
          }],
        ].each do |args|
          options = args.pop
          send(*args, **options)
          conflicts "--formula", args.last
        end
        cask_options

        conflicts "--build-from-source", "--force-bottle"

        named_args [:formula, :cask], min: 1
      end

      sig { override.void }
      def run
        formulae, casks = args.named.to_resolved_formulae_to_casks

        if args.build_from_source?
          unless DevelopmentTools.installed?
            raise BuildFlagsError.new(["--build-from-source"], bottled: formulae.all?(&:bottled?))
          end

          unless Homebrew::EnvConfig.developer?
            opoo "building from source is not supported!"
            puts "You're on your own. Failures are expected so don't create any issues, please!"
          end
        end

        formulae = Homebrew::Attestation.sort_formulae_for_install(formulae) if Homebrew::Attestation.enabled?

        unless formulae.empty?
          Install.perform_preinstall_checks_once

          ask_input = lambda {
            ohai "Do you want to proceed with the installation? [Y/y/yes/N/n]"
            accepted_inputs = %w[y yes]
            declined_inputs = %w[n no]
            loop do
              result = $stdin.gets.chomp.strip.downcase
              if accepted_inputs.include?(result)
                puts "Proceeding with installation..."
                break
              elsif declined_inputs.include?(result)
                exit 0
              else
                puts "Invalid input. Please enter 'Y', 'y', or 'yes' to proceed, or 'N' to abort."
              end
            end
          }

          # Build a unique list of formulae to size by including:
          # 1. The original formulae to install.
          # 2. Their outdated dependents (subject to pruning criteria).
          # 3. Optionally, any installed formula that depends on one of these and is outdated.
          compute_sized_formulae = lambda { |formulae_to_install, check_dep: true|
            sized_formulae = formulae_to_install.flat_map do |formula|
              # Always include the formula itself.
              formula_list = [formula]

              # If there are dependencies, try to gather outdated, bottled ones.
              if formula.deps.any? && check_dep
                outdated_dependents = formula.recursive_dependencies do |_, dep|
                  dep_formula = dep.to_formula
                  next :prune if dep_formula.deps.empty?
                  next :prune unless dep_formula.outdated?
                  next :prune unless dep_formula.bottled?
                end.flatten

                # Convert each dependency to its formula.
                formula_list.concat(outdated_dependents.flat_map { |dep| Array(dep.to_formula) })
              end

              formula_list
            end

            # Add any installed formula that depends on one of the sized formulae and is outdated.
            if !Homebrew::EnvConfig.no_installed_dependents_check? && check_dep
              installed_outdated = Formula.installed.select do |installed_formula|
                installed_formula.outdated? &&
                  installed_formula.deps.any? { |dep| sized_formulae.include?(dep.to_formula) }
              end
              sized_formulae.concat(installed_outdated)
            end

            # Uniquify based on a string representation (or any unique identifier)
            sized_formulae.uniq(&:to_s)
          }

          # Compute the total sizes (download, installed, and net) for the given formulae.
          compute_total_sizes = lambda { |sized_formulae, debug: false|
            total_download_size  = 0
            total_installed_size = 0
            total_net_size       = 0

            sized_formulae.each do |formula|
              next unless (bottle = formula.bottle)

              # Fetch additional bottle metadata (if necessary).
              bottle.fetch_tab(quiet: !debug)

              total_download_size  += bottle.bottle_size.to_i if bottle.bottle_size
              total_installed_size += bottle.installed_size.to_i if bottle.installed_size

              # Sum disk usage for all installed kegs of the formula.
              next if formula.installed_kegs.none?

              kegs_dep_size = formula.installed_kegs.sum { |keg| keg.disk_usage.to_i }
              total_net_size += bottle.installed_size.to_i - kegs_dep_size if bottle.installed_size
            end

            { download:  total_download_size,
              installed: total_installed_size,
              net:       total_net_size }
          }

          # Main block: if asking the user is enabled, show dependency and size information.
          # This part should be
          if args.ask?
            ohai "Looking for bottles..."

            sized_formulae = compute_sized_formulae.call(formulae, check_dep: false)
            sizes = compute_total_sizes.call(sized_formulae, debug: args.debug?)

            puts "Formulae: #{sized_formulae.join(", ")}\n\n"
            puts "Download Size: #{disk_usage_readable(sizes[:download])}"
            puts "Install Size:  #{disk_usage_readable(sizes[:installed])}"
            puts "Net Install Size: #{disk_usage_readable(sizes[:net])}" if sizes[:net] != 0

            ask_input.call
          end

          formulae.each do |formula|
            if formula.pinned?
              onoe "#{formula.full_name} is pinned. You must unpin it to reinstall."
              next
            end
            Migrator.migrate_if_needed(formula, force: args.force?)
            Homebrew::Reinstall.reinstall_formula(
              formula,
              flags:                      args.flags_only,
              force_bottle:               args.force_bottle?,
              build_from_source_formulae: args.build_from_source_formulae,
              interactive:                args.interactive?,
              keep_tmp:                   args.keep_tmp?,
              debug_symbols:              args.debug_symbols?,
              force:                      args.force?,
              debug:                      args.debug?,
              quiet:                      args.quiet?,
              verbose:                    args.verbose?,
              git:                        args.git?,
            )
            Cleanup.install_formula_clean!(formula)
          end

          Upgrade.check_installed_dependents(
            formulae,
            flags:                      args.flags_only,
            force_bottle:               args.force_bottle?,
            build_from_source_formulae: args.build_from_source_formulae,
            interactive:                args.interactive?,
            keep_tmp:                   args.keep_tmp?,
            debug_symbols:              args.debug_symbols?,
            force:                      args.force?,
            debug:                      args.debug?,
            quiet:                      args.quiet?,
            verbose:                    args.verbose?,
          )
        end

        if casks.any?
          Cask::Reinstall.reinstall_casks(
            *casks,
            binaries:       args.binaries?,
            verbose:        args.verbose?,
            force:          args.force?,
            require_sha:    args.require_sha?,
            skip_cask_deps: args.skip_cask_deps?,
            quarantine:     args.quarantine?,
            zap:            args.zap?,
          )
        end

        Cleanup.periodic_clean!

        Homebrew.messages.display_messages(display_times: args.display_times?)
      end
    end
  end
end
