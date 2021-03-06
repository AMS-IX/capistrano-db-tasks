module Database
  class Base

    attr_accessor :config, :output_file, :schemas

    def initialize(cap_instance)
      @cap = cap_instance
      @schemas = []
    end

    def mysql?
      @config['adapter'] =~ /^mysql/
    end

    def postgresql?
      %w(postgresql pg postgis).include? @config['adapter']
    end

    def credentials
      credential_params = ""
      username = @config['username'] || @config['user']

      if mysql?
        credential_params << " -u #{username} " if username
        credential_params << " -p'#{@config['password']}' " if @config['password']
        credential_params << " -h #{@config['host']} " if @config['host']
        credential_params << " -S #{@config['socket']} " if @config['socket']
        credential_params << " -P #{@config['port']} " if @config['port']
      elsif postgresql?
        credential_params << " -U #{username} " if username
        credential_params << " -h #{@config['host']} " if @config['host']
        credential_params << " -p #{@config['port']} " if @config['port']
      end

      credential_params
    end

    def database
      @config['database']
    end

    def current_time
      Time.now.strftime("%Y-%m-%d-%H%M%S")
    end

    def output_file
      @output_file ||= "db/#{database}_#{current_time}.sql.#{compressor.file_extension}"
    end

    def compressor
      @compressor ||= begin
        compressor_klass = @cap.fetch(:compressor).to_s.split('_').collect(&:capitalize).join
        klass = Object.module_eval("::Compressors::#{compressor_klass}", __FILE__, __LINE__)
        klass
      end
    end

  private

    def pgpass
      @config['password'] ? "PGPASSWORD='#{@config['password']}'" : ""
    end

    def dump_cmd
      if mysql?
        "mysqldump #{credentials} #{database} #{dump_cmd_opts}"
      elsif postgresql?
        "#{pgpass} pg_dump #{credentials} #{database} #{dump_cmd_opts}"
      end
    end

    def import_cmd(file)
      if mysql?
        "mysql #{credentials} -D #{database} < #{file}"
      elsif postgresql?
        terminate_connection_sql = "SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.datname = '#{database}' AND pid <> pg_backend_pid();"
        if @schemas && @schemas.any?
          remove_schemas_sql = "#{@schemas.map{|s| "DROP SCHEMA IF EXISTS #{s} CASCADE; CREATE SCHEMA #{s};"}.join(' ')}"
          "#{pgpass} psql -v ON_ERROR_STOP=1 -d #{database} #{credentials} -c \"#{terminate_connection_sql} #{remove_schemas_sql}\"; #{pgpass} psql #{credentials} -d #{database} < #{file}"
        else
          "#{pgpass} psql -c \"#{terminate_connection_sql};\" #{credentials}; #{pgpass} dropdb #{credentials} #{database}; #{pgpass} createdb #{credentials} #{database}; #{pgpass} psql #{credentials} -d #{database} < #{file}"
        end
      end
    end

    def dump_cmd_opts
      if mysql?
        "--lock-tables=false #{dump_cmd_ignore_tables_opts} #{dump_cmd_ignore_data_tables_opts}"
      elsif postgresql?
        options = "--no-acl --no-owner #{dump_cmd_ignore_tables_opts} #{dump_cmd_ignore_data_tables_opts}"
        if @schemas && schemas.any?
          options += @schemas.map{|s| " -n #{s}"}.join
        end
        options
      end
    end

    def dump_cmd_ignore_tables_opts
      ignore_tables = @cap.fetch(:db_ignore_tables, [])
      if mysql?
        ignore_tables.map{ |t| "--ignore-table=#{database}.#{t}" }.join(" ")
      elsif postgresql?
        ignore_tables.map{ |t| "--exclude-table=#{t}" }.join(" ")
      end
    end

    def dump_cmd_ignore_data_tables_opts
      ignore_tables = @cap.fetch(:db_ignore_data_tables, [])
      if postgresql?
        ignore_tables.map{ |t| "--exclude-table-data=#{t}" }.join(" ")
      end
    end

  end

  class Remote < Base
    def initialize(cap_instance)
      super(cap_instance)
      @config = @cap.capture("cat #{@cap.current_path}/config/database.yml")
      @config = YAML.load(ERB.new(@config).result)[@cap.fetch(:rails_env).to_s]
    end

    def dump
      @cap.execute "cd #{@cap.current_path} && #{dump_cmd} | #{compressor.compress('-', output_file)}"
      self
    end

    def download(local_file = "#{output_file}")
      @cap.download! dump_file_path, local_file
    end

    def clean_dump_if_needed
      if @cap.fetch(:db_remote_clean)
        @cap.execute "rm -f #{dump_file_path}"
      else
        @cap.info "leaving #{dump_file_path} on the server (add \"set :db_remote_clean, true\" to deploy.rb to remove)"
      end
    end

    # cleanup = true removes the mysqldump file after loading, false leaves it in db/
    def load(file, cleanup)
      unzip_file = File.join(File.dirname(file), File.basename(file, ".#{compressor.file_extension}"))
      # @cap.run "cd #{@cap.current_path} && bunzip2 -f #{file} && RAILS_ENV=#{@cap.rails_env} bundle exec rake db:drop db:create && #{import_cmd(unzip_file)}"
      @cap.execute "cd #{@cap.current_path} && #{compressor.decompress(file)} && RAILS_ENV=#{@cap.fetch(:rails_env)} && #{import_cmd(unzip_file)}"
      @cap.execute("cd #{@cap.current_path} && rm #{unzip_file}") if cleanup
    end

    private

    def dump_file_path
      "#{@cap.current_path}/#{output_file}"
    end
  end

  class Local < Base
    def initialize(cap_instance)
      super(cap_instance)
      @config = YAML.load(ERB.new(File.read(File.join('config', 'database.yml'))).result)[fetch(:local_rails_env).to_s]
    end

    # cleanup = true removes the mysqldump file after loading, false leaves it in db/
    def load(file, cleanup)
      unzip_file = File.join(File.dirname(file), File.basename(file, ".#{compressor.file_extension}"))
      # execute("bunzip2 -f #{file} && bundle exec rake db:drop db:create && #{import_cmd(unzip_file)} && bundle exec rake db:migrate")
      @cap.info "executing local: #{compressor.decompress(file)}" && #{import_cmd(unzip_file)}"
      imprt_cmd = import_cmd(unzip_file)
      execute("#{compressor.decompress(file)} && #{import_cmd(unzip_file)}")
      if cleanup
        @cap.info "removing #{unzip_file}"
        File.unlink(unzip_file)
      else
        @cap.info "leaving #{unzip_file} (specify :db_local_clean in deploy.rb to remove)"
      end
      @cap.info "Completed database import"
    end

    def dump
      execute "#{dump_cmd} | #{compressor.compress('-', output_file)}"
      self
    end

    def upload
      remote_file = "#{@cap.current_path}/#{output_file}"
      @cap.upload! output_file, remote_file
    end

    def remove_sensitive_data(schemas)
      # Accepts a list of schemas, for example [nl:us]
      # meaning "replace emails for shards nl and us"

      schemas = [schemas] unless schemas.is_a? Array

      puts "Local database: removing sensitive data, hold tight..."
      for schema in schemas do
        stdout3, status3 = Open3.capture2('bundle', 'exec', 'rake', "replace_emails_in_database[#{schema}]")
        puts stdout3
        puts status3
      end
    end

    private

    def execute(cmd)
      result = system cmd
      @cap.error "Failed to execute the local command: #{cmd}" unless result
      result
    end
  end


  class << self
    def check(local_db, remote_db)
      unless (local_db.mysql? && remote_db.mysql?) || (local_db.postgresql? && remote_db.postgresql?)
        raise 'Only mysql or postgresql on remote and local server is supported'
      end
    end

    def remote_to_local(instance)
      local_db  = Database::Local.new(instance)
      remote_db = Database::Remote.new(instance)

      check(local_db, remote_db)

      begin
        remote_db.dump.download
      ensure
        remote_db.clean_dump_if_needed
      end
      local_db.load(remote_db.output_file, instance.fetch(:db_local_clean))
    end

    def selective_schemas_to_local(instance, schemas = [])
      local_db  = Database::Local.new(instance)
      remote_db = Database::Remote.new(instance)
      local_db.schemas = schemas
      remote_db.schemas = schemas
      check(local_db, remote_db)

      begin
        remote_db.dump.download
      ensure
        remote_db.clean_dump_if_needed
      end
      local_db.load(remote_db.output_file, instance.fetch(:db_local_clean))      
    end


    def local_to_remote(instance)
      local_db  = Database::Local.new(instance)
      remote_db = Database::Remote.new(instance)

      check(local_db, remote_db)

      local_db.dump.upload
      remote_db.load(local_db.output_file, instance.fetch(:db_local_clean))
      File.unlink(local_db.output_file) if instance.fetch(:db_local_clean)
    end
  end

end
