require 'droplet_kit'
require 'optimist'
require 'pry'
require_relative './script'
require_relative './db'

# Grab the database for keeping track of configurations and VMs.
db = DB.new
# Initialize the client. Try to get the token from the database and if it is not there
# then get it from the environment and save it to the database.
token = ENV['DO_TOKEN'] || (raise StandardError, "Provide digital ocean token with DO_TOKEN environment variable.")
client = DropletKit::Client.new(access_token: token)

# Now we parse some arguments.
subcommands = %w(create destroy configuration list)
Optimist::options do
  banner <<-EOS
Manage wireguard VPNs from the command line.
Usage:
  [DO_TOKEN=$TOKEN] bundle exec ruby do-wireguard-vpn.rb [#{subcommands.join('|')}] [subcommand options]
EOS
  stop_on subcommands
end
case (cmd = ARGV.shift)
when 'create'
  # Just fall through since the default action is creation.
when 'destroy'
  # Indiscriminate destruction.
  opts = Optimist::options do
    opt :id, "ID of the VM to destroy", type: :string
    opt :force, default: true
  end
  id = (opts[:id] || Optimist::die("--id parameter is required for VM destruction.")).to_i
  begin
    client.droplets.delete(id: id)
  rescue StandardError => e
    raise e unless opts[:force]
  end
  db.delete(id)
  exit
when 'configuration'
  opts = Optimist::options do
    opt :id, "ID of the VM for the client configuration", type: :string
  end
  Optimist::die("--id parameter is required for listing client configuration.") if opts[:id].nil?
  STDOUT.puts db.configuration(opts[:id])
  exit
when 'list'
  STDOUT.puts db.list
  exit
else
  Optimist::die "Unknown subcommand: #{cmd.inspect}."
end

client_conf_location = "/tmp/wireguard-client.conf"
server_conf_location = "/etc/wireguard/wg0.conf"
setup_script = SetupScript[
  server_subnet: "10.200.200.1/24",
  server_port: "51820",
  client_address: "10.200.200.2/32",
  client_conf_location: client_conf_location,
  server_conf_location: server_conf_location
]
# Grab the ssh keys assuming one of them is available locally and will let us log in.
ssh_keys = client.ssh_keys.all.map { |k| k.fingerprint }
# Dump the userdata script locally for debugging purposes.
File.open('/tmp/wireguard-userdata.sh', 'w') { |f| f.puts setup_script[0] }
after_reboot_script = '/tmp/wireguard-after-reboot-script.sh'
File.open(after_reboot_script, 'w') { |f| f.puts setup_script[1] }
# Create a new droplet with the above inline script as the userdata script.
droplet = DropletKit::Droplet.new(
  names: ['wireguard-vpn'],
  image: 'ubuntu-19-10-x64',
  # Pick a random region or whatever is in DO_REGION environment variable
  region: ENV['DO_REGION'] || client.regions.all.map { |r| r.slug }.sample, 
  size: 's-1vcpu-1gb',
  ipv6: false,
  user_data: setup_script[0],
  tags: ['wireguard', 'vpn'],
  ssh_keys: ssh_keys
)
# Kick off the droplet creation process.
response = client.droplets.create_multiple(droplet).first
STDERR.puts "Waiting for IP address."
# Create our model of the droplet so we can start acting on it.
droplet_model = db.new_droplet(response, client)
while !droplet_model.ready?
  sleep 5
end
STDOUT.puts "Got IP address: #{droplet_model.ip_address}."
# Now we try to ssh in and grab the client configuration.
ssh_command = "if [[ ! -e #{client_conf_location} ]]; then echo 'waiting'; else echo 'done'; fi".freeze
STDERR.puts "Waiting for configuration file to be created."
while (ready = droplet_model.ssh_command(ssh_command, "2> /dev/null").strip).empty? || ready[/^waiting$/]
  sleep 5
end
STDERR.puts "Configuration file created on the remote host so copying it to local host."
# Save the configurations to the database.
droplet_model.client_configuration = (client_configuration = droplet_model.ssh_command("cat #{client_conf_location}", "2> /dev/null | tee /tmp/wireguard-client.conf").strip)
droplet_model.server_configuration = (server_configuration = droplet_model.ssh_command("cat #{server_conf_location}", "2> /dev/null | tee /tmp/wireguard-server.conf").strip)
# Restart the server.
STDERR.puts "Restarting VM just in case any changes require a restart."
droplet_model.ssh_command("shutdown -r now", "&> /dev/null")
# Write out the configuration contents. Can be compared with /tmp/wireguard-client.conf. They should be the same.
File.open(File.basename(client_conf_location), 'w') { |f| f.puts client_configuration }
File.open(File.basename(server_conf_location), 'w') { |f| f.puts server_configuration }
# Wait for server to reboot.
until (ready = droplet_model.ssh_command("echo ready", "").strip)[/ready/]
  sleep 5
end
# Copy after reboot script to the host.
droplet_model.copy_file(after_reboot_script, "after-reboot.sh")
# Execute the script to bring up wireguard and set up IP table rules.
STDOUT.puts droplet_model.ssh_command("/bin/bash after-reboot.sh", "")
db.close
