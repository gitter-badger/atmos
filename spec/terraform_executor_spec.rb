require 'atmos/terraform_executor'

describe Atmos::TerraformExecutor do
  let(:te) { described_class.new(Hash.new) }

  after :all do
    Atmos.config = nil
  end

  describe "pipe_stream" do

    it "pipes data between streams" do
      r, w = IO.pipe
      dest = StringIO.new

      t = te.send(:pipe_stream, r, dest)
      w.puts("foo")
      w.puts("bar")
      w.close
      t.join
      expect(dest.string).to eq("foo\nbar\n")
    end

    it "handles data without newline" do
      r, w = IO.pipe
      dest = StringIO.new

      t = te.send(:pipe_stream, r, dest)
      w.write("foo")
      sleep 0.1
      expect(dest.string).to eq("foo")

      w.close
      t.join
      expect(dest.string).to eq("foo")
    end

    it "can markup data with a block" do
      r, w = IO.pipe
      dest = StringIO.new

      t = te.send(:pipe_stream, r, dest) do |data|
        "1#{data}2"
      end
      w.write("foo")
      w.close
      t.join
      expect(dest.string).to eq("1foo2")
    end

  end

  describe "link_recipes" do

    it "links recipes into working dir" do
      within_construct do |c|
        c.file('config/atmos.yml', YAML.dump('recipes' => ['foo', 'bar']))
        c.file('recipes/foo.tf')
        c.file('recipes/bar.tf')
        Atmos.config = Atmos::Config.new("ops")
        te.send(:link_recipes)
        ['foo', 'bar'].each do |f|
          link = File.join(Atmos.config.tf_working_dir, "#{f}.tf")
          expect(File.symlink?(link)).to be true
          expect(File.readlink(link)).to eq(File.join(Atmos.config.root_dir, "recipes/#{f}.tf"))
        end
      end

    end

  end

  describe "link_support_dirs" do

    it "links dirs into working dir" do
      within_construct do |c|
        c.file('config/atmos.yml')
        c.directory('modules')
        c.directory('templates')
        c.file('recipes/foo.tf')

        Atmos.config = Atmos::Config.new("ops")
        te.send(:link_support_dirs)
        te.send(:link_support_dirs)
        ['modules', 'templates'].each do |f|
          link = File.join(Atmos.config.tf_working_dir, "#{f}")
          expect(File.symlink?(link)).to be true
          expect(File.readlink(link)).to eq(File.join(Atmos.config.root_dir, "#{f}"))
        end
      end

    end

  end

  describe "clean_links" do

    it "links dirs into working dir" do
      within_construct do |c|
        c.file('config/atmos.yml', YAML.dump('recipes' => ['foo']))
        c.directory('modules')
        c.directory('templates')
        Atmos.config = Atmos::Config.new("ops")
        te.send(:link_support_dirs)
        te.send(:link_recipes)

        count = 0
        Find.find(Atmos.config.tf_working_dir) {|f|  count += 1 if File.symlink?(f) }
        expect(count).to eq(3)

        te.send(:clean_links)
        count = 0
        Find.find(Atmos.config.tf_working_dir) {|f|  count += 1 if File.symlink?(f) }
        expect(count).to eq(0)
      end

    end

  end

  describe "secrets_env" do

    it "passes secrets as env vars" do
      within_construct do |c|
        c.file('config/atmos.yml', YAML.dump('providers' => {'aws' => {'secret' => {}}}))
        Atmos.config = Atmos::Config.new("ops")
        expect(Atmos.config.provider.secret_manager).to receive(:to_h).
            and_return({"s1" => "a1", "s2" => "a2"})

        env = te.send(:secrets_env)
        expect(env).to eq({"TF_VAR_s1" => "a1", "TF_VAR_s2" => "a2"})
      end

    end

  end

  describe "write_atmos_vars" do

    it "writes the terraform var file for atmos vars" do
      within_construct do |c|
        c.file('config/atmos.yml', YAML.dump(
            'foo' => 'bar',
            'baz' => {'boo' => 'bum'},
            'environments' => {
                'ops' => {
                    'account_id' => 123
                }
            }
        ))
        Atmos.config = Atmos::Config.new("ops")
        te.send(:write_atmos_vars)

        file = File.join(Atmos.config.tf_working_dir, 'atmos.auto.tfvars.json')
        expect(File.exist?(file)).to be true
        vars = JSON.parse(File.read(file))
        expect(vars['environment']).to eq('ops')
        expect(vars['account_ids']).to eq("ops" => 123)
        expect(vars['atmos_config']['foo']).to eq('bar')
        expect(vars['atmos_config']['baz_boo']).to eq('bum')
        expect(vars['foo']).to eq('bar')
        expect(vars['baz_boo']).to eq('bum')
      end
    end

    it "honors var_prefix if set" do
      within_construct do |c|
        c.file('config/atmos.yml', YAML.dump(
            'var_prefix' => 'myprefix_',
            'foo' => 'bar',
            'baz' => {'boo' => 'bum'},
            'environments' => {
                'ops' => {
                    'account_id' => 123
                }
            }
        ))
        Atmos.config = Atmos::Config.new("ops")
        te.send(:write_atmos_vars)

        file = File.join(Atmos.config.tf_working_dir, 'atmos.auto.tfvars.json')
        expect(File.exist?(file)).to be true
        vars = JSON.parse(File.read(file))
        expect(vars['environment']).to eq('ops')
        expect(vars['account_ids']).to eq("ops" => 123)
        expect(vars['atmos_config']['foo']).to eq('bar')
        expect(vars['atmos_config']['baz_boo']).to eq('bum')
        expect(vars['myprefix_foo']).to eq('bar')
        expect(vars['myprefix_baz_boo']).to eq('bum')
      end
    end

  end

  describe "homogenize_for_terraform" do

    it "handles empty maps" do
      expect(te.send(:homogenize_for_terraform, {})).to eq({})
    end

    it "handles basic maps" do
      expect(te.send(:homogenize_for_terraform, {"k1" => 1})).to eq({"k1" => 1})
    end

    it "handles basic arrays" do
      expect(te.send(:homogenize_for_terraform, {"k1" => [1,2]})).to eq({"k1" => "1,2"})
    end

    it "flattens deep maps" do
      expect(te.send(:homogenize_for_terraform,
                     {"k1" => {"k2" => 2, "k3" => 3, "k4" => {"k5" => 5, "k6" => [4, 5, 6]}}})).
          to eq({"k1_k2" => 2, "k1_k3" => 3, "k4_k5" => 5, "k4_k6" => "4,5,6"})
    end

  end

  describe "setup_backend" do

    it "writes the terraform backend file" do
      within_construct do |c|
        c.file('config/atmos.yml', YAML.dump(
            'foo' => 'bar',
            'providers' => {
                'aws' => {
                  'backend' => {
                      'type' => "mytype",
                      'foo' => 'bar',
                      'baz' => 'boo'
                  }
                }
            }
        ))
        Atmos.config = Atmos::Config.new("ops")
        te.send(:setup_backend)

        file = File.join(Atmos.config.tf_working_dir, 'atmos-backend.tf.json')
        expect(File.exist?(file)).to be true
        vars = JSON.parse(File.read(file))
        expect(vars['terraform']['backend']['mytype']).
            to eq('foo' => 'bar',
                  'baz' => 'boo')
      end
    end

    it "skips the terraform backend" do
      within_construct do |c|
        c.file('config/atmos.yml')
        Atmos.config = Atmos::Config.new("ops")
        te.send(:setup_backend, true)

        file = File.join(Atmos.config.tf_working_dir, 'atmos-backend.tf.json')
        expect(File.exist?(file)).to be false
      end
    end

    it "deletes the terraform backend when skipping" do
      within_construct do |c|
        c.file('config/atmos.yml')
        Atmos.config = Atmos::Config.new("ops")

        file = File.join(Atmos.config.tf_working_dir, 'atmos-backend.tf.json')
        c.file(file)

        te.send(:setup_backend, true)

        expect(File.exist?(file)).to be false
      end
    end

    it "deletes the terraform backend when not skipping but no config" do
      within_construct do |c|
        c.file('config/atmos.yml')
        Atmos.config = Atmos::Config.new("ops")

        file = File.join(Atmos.config.tf_working_dir, 'atmos-backend.tf.json')
        c.file(file)

        te.send(:setup_backend)

        expect(File.exist?(file)).to be false
      end
    end

  end

  describe "setup_working_dir" do

    it "performs the setup steps" do
      within_construct do |c|
        c.file('config/atmos.yml')
        Atmos.config = Atmos::Config.new("ops")

        expect(te).to receive(:clean_links)
        expect(te).to receive(:link_support_dirs)
        expect(te).to receive(:link_recipes)
        expect(te).to receive(:write_atmos_vars)
        expect(te).to receive(:setup_backend)

        te.send(:setup_working_dir)
      end
    end

  end

  describe "run" do

    it "performs the setup and execution steps" do
      within_construct do |c|
        c.file('config/atmos.yml')
        Atmos.config = Atmos::Config.new("ops")

        expect(te).to receive(:setup_working_dir)
        expect(te).to receive(:execute)

        te.send(:run)
      end
    end

  end

  describe "execute" do

    it "passes secrets via env terraform" do
      within_construct do |c|
        c.file('config/atmos.yml')
        Atmos.config = Atmos::Config.new("ops")

        expect(te).to receive(:secrets_env).and_return({'foo' => 'bar'})
        expect(te).to receive(:spawn).with(hash_including('foo' => 'bar'), any_args)
        expect(Process).to receive(:wait)

        te.send(:execute, "init", skip_secrets: false)
      end
    end

    it "skips secrets when desired" do
      within_construct do |c|
        c.file('config/atmos.yml')
        Atmos.config = Atmos::Config.new("ops")

        expect(te).to_not receive(:secrets_env)
        expect(te).to receive(:spawn)
        expect(Process).to receive(:wait)

        te.send(:execute, "init", skip_secrets: true)
      end
    end

    it "runs terraform" do
      within_construct do |c|
        c.file('config/atmos.yml')
        Atmos.config = Atmos::Config.new("ops")

        expect { te.send(:execute, "init", skip_secrets: true) }.
            to output(/Terraform initialized in an empty directory/).to_stdout
      end
    end

    it "runs terraform with stderr" do
      within_construct do |c|
        c.file('config/atmos.yml')
        Atmos.config = Atmos::Config.new("ops")

        expect { te.send(:execute, "init", "-badarg", skip_secrets: true) rescue Atmos::TerraformExecutor::ProcessFailed }.
            to output(/flag provided but not defined/).to_stderr
      end
    end

    it "runs terraform with stdin" do
      within_construct do |c|
        c.file('config/atmos.yml')
        Atmos.config = Atmos::Config.new("ops")

        c.file(File.join(Atmos.config.tf_working_dir, 'stdin.tf.json'), JSON.dump(
                    'variable' => {
                        'needed' => {}
                    },
                    'output' => {
                        'showme' => {
                            'value' => 'got var ${var.needed}'
                        }
                    }
                ))

        expect { te.send(:execute, "init", skip_secrets: true) }.
            to output(/Terraform has been successfully initialized/).to_stdout

        # We redirect terminal stdin to process using spawn (:in => :in), as
        # other methods weren't reliable.  As a resut, we can't simply simulate
        # stdin with an IO, so hack it this way
        c.file(File.join(Atmos.config.tf_working_dir, "stdin.txt"), "foo\nyes\n")
        allow(te).to receive(:tf_cmd).and_return(["bash", "-c", "cat stdin.txt | terraform apply"])
        expect {
            te.send(:execute, "apply", skip_secrets: true)
        }.to output(/showme = got var foo/).to_stdout
      end
    end

  end

end
