# frozen_string_literal: true
require "gemnasium/parser"
require "bundler"
require "bump/dependency_file"
require "bump/shared_helpers"
require "bump/dependency_file_updaters/errors"

module Bump
  module DependencyFileUpdaters
    class Ruby
      attr_reader :gemfile, :gemfile_lock, :dependency

      def initialize(dependency_files:, dependency:)
        @gemfile = dependency_files.find { |f| f.name == "Gemfile" }
        @gemfile_lock = dependency_files.find { |f| f.name == "Gemfile.lock" }
        validate_files_are_present!

        @dependency = dependency
      end

      def updated_dependency_files
        [updated_gemfile, updated_gemfile_lock]
      end

      def updated_gemfile
        DependencyFile.new(
          name: "Gemfile",
          content: updated_gemfile_content
        )
      end

      def updated_gemfile_lock
        DependencyFile.new(
          name: "Gemfile.lock",
          content: updated_gemfile_lock_content
        )
      end

      private

      def validate_files_are_present!
        raise "No Gemfile!" unless gemfile
        raise "No Gemfile.lock!" unless gemfile_lock
      end

      def updated_gemfile_content
        return @updated_gemfile_content if @updated_gemfile_content

        gemfile.content.
          to_enum(:scan, Gemnasium::Parser::Patterns::GEM_CALL).
          find { Regexp.last_match[:name] == dependency.name }

        original_gem_declaration_string = Regexp.last_match.to_s
        updated_gem_declaration_string =
          original_gem_declaration_string.
          sub(Gemnasium::Parser::Patterns::REQUIREMENTS) do |old_requirements|
            old_version =
              old_requirements.match(Gemnasium::Parser::Patterns::VERSION)[0]

            precision = old_version.split(".").count
            new_version =
              dependency.version.split(".").first(precision).join(".")

            old_requirements.sub(old_version, new_version)
          end

        @updated_gemfile_content = gemfile.content.gsub(
          original_gem_declaration_string,
          updated_gem_declaration_string
        )
      end

      def updated_gemfile_lock_content
        @updated_gemfile_lock_content ||= build_updated_gemfile_lock
      end

      def build_updated_gemfile_lock
        SharedHelpers.in_a_temporary_directory do |dir|
          write_temporary_dependency_files_to(dir)

          SharedHelpers.in_a_forked_process do
            definition = Bundler::Definition.build(
              File.join(dir, "Gemfile"),
              File.join(dir, "Gemfile.lock"),
              gems: [dependency.name]
            )
            definition.resolve_remotely!
            definition.to_lock.gsub(
              "https://#{bump_github_token}:x-oauth-basic@github.com/",
              "git@github.com:"
            )
          end
        end
      rescue SharedHelpers::ChildProcessFailed => error
        if error.error_class == "Bundler::VersionConflict"
          raise DependencyFileUpdaters::VersionConflict
        end

        raise
      end

      def write_temporary_dependency_files_to(dir)
        File.write(
          File.join(dir, "Gemfile"),
          updated_gemfile_content.gsub(
            "git@github.com:",
            "https://#{bump_github_token}:x-oauth-basic@github.com/"
          )
        )
        File.write(
          File.join(dir, "Gemfile.lock"),
          gemfile_lock.content.gsub(
            "git@github.com:",
            "https://#{bump_github_token}:x-oauth-basic@github.com/"
          )
        )
      end

      def bump_github_token
        Prius.get(:bump_github_token)
      end
    end
  end
end
