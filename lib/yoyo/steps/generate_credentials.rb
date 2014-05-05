require 'sixword'
require 'mail'

# I debug things:
require 'pry'

module Yoyo;
  module Steps
    class GenerateCredentials < Yoyo::StepList
      def dot_stripe
        File.expand_path("~/.stripe")
      end

      def set_fingerprint(fpr)
        @fingerprint = fpr
      end

      attr_reader :fingerprint

      def stripe_email
        @key_parse_done ||=
          begin
            Subprocess.check_call(%W{gpg --no-tty --with-colons --list-key #{fingerprint}},
                                  :stdout => Subprocess::PIPE,
                                  :stdin => nil) do |process|
              output, err = process.communicate
              uids = []
              output.each_line do |line|
                abbrev, rest = line.chomp.split(':', 2)
                if abbrev == 'uid'
                  uids << Mail::Address.new(rest.split(':').last)
                end
              end
              log.debug("Found UIDs on key: #{uids}")
              @stripe_email = uids.find { |addr| addr.domain == 'stripe.com' }
              log.debug("Found @stripe.com UID #{@stripe_email}")
            end
            true
          end
        @stripe_email
      end

      def dot_stripe_clean?
        # Any staged but uncommitted changes? Exit status 1 = yep.
        Subprocess.check_call(%w{git diff-index --quiet HEAD}, :cwd => dot_stripe)
        # Any unstaged changes? Exit status 1 = yep.
        Subprocess.check_call(%w{git diff-files --quiet}, :cwd => dot_stripe)
        true
      rescue Subprocess::NonZeroExit
        false
      end

      def init_steps
        step 'read SSH key' do
          idempotent

          run do
            log.info <<-EOM
Seems like Marionetting worked! Congrats! Now, on the target machine, run:

     /usr/local/stripe/bin/generate-stripe-keys [stripe-username]@stripe.com

And wait for it to print the words of six. Then, enter them here:
EOM
            fingerprint = ""
            while fingerprint.length < 40
              fingerprint += Sixword::Lib.decode_6_words($stdin.readline.split(' '), true).to_s(16)
            end
            raise "Fingerprint doesn't look right" unless fingerprint.length == 40
            set_fingerprint(fingerprint)
          end
        end

        step 'gpg-sign their key' do
          complete? do
            begin
              Subprocess.check_call(%W{./gnupg/is_key_signed.sh #{fingerprint}}, :cwd => dot_stripe)
              true
            rescue Subprocess::NonZeroExit
              false
            end
          end

          run do
            raise "~/.stripe has uncommitted stuff in it! Clean it up, please!" unless dot_stripe_clean?
            Subprocess.check_call(%w{./bin/dot-git pull}, :cwd => dot_stripe)

            space_commander = File.expand_path("~/stripe/space-commander/bin")
            Bundler.with_clean_env do
              Subprocess.check_call(%W{bash -x ./gnupg/sign_gpg_key_with_ca.sh #{fingerprint}},
                                    :cwd => dot_stripe)
            end
          end
        end

        step 'fetch stripe GPG keys' do
          idempotent

          run do
            Bundler.with_clean_env do
              Subprocess.check_call(%w{fetch-stripe-gpg-keys})
            end
          end
        end

        step 'generate VPN certs' do
          complete? do
            !Dir.glob(File.expand_path("stripe.vpn/#{stripe_email.local}-[0-9]*.tar.gz.gpg", dot_stripe)).empty?
          end

          run do
            Bundler.with_clean_env do
              Subprocess.check_call(%W{./stripe.vpn/add_certs.sh #{stripe_email.local} #{stripe_email.name}},
                                    :cwd => dot_stripe)
            end
          end
        end

        step 'commit ~/.stripe' do
          complete? do
            dot_stripe_clean?
          end

          run do
            log.debug("Adding files...")
            Subprocess.check_call(%w{git add .}, :cwd => dot_stripe)
            log.debug("Added files...")
            message = "Provision #{stripe_email.to_s} with GPG fingerprint #{fingerprint}"
            Subprocess.check_call(%W{git commit -m #{message}}, :cwd => dot_stripe)
          end
        end

        step 'push ~/.stripe' do
          idempotent

          run do
            Subprocess.check_call(%w{bin/dot-git push}, :cwd => dot_stripe)
          end
        end

        step 'copy VPN certs to machine' do
          idempotent

          run do
            all_certs = Dir.glob(File.expand_path("stripe.vpn/#{stripe_email.local}-[0-9]*.tar.gz.gpg", dot_stripe))
            latest_cert = all_certs.sort_by { |filename|
              File.stat(filename).mtime
            }.last

            log.debug("Latest cert file we have for this stripe is #{latest_cert}")

            mgr.ssh.file_write(File.join('Desktop', 'certs.tar.gz.gpg'), File.read(latest_cert))
            log.info("Now you can run /usr/local/stripe/bin/import-vpn-certs ~/Desktop/certs.tar.gz.gpg")
          end
        end

        # step 'add GPG-signed SSH key to puppet' do
        #
        # end
      end
    end
  end
end