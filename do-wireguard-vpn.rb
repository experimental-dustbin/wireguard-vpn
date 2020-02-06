require 'droplet_kit'

client_conf_location = "/tmp/wireguard-client.conf"
server_subnet = "10.200.200.1/24"
server_port = "51820"
client_address = "10.200.200.2/32"
setup_script = <<-SETUPSCRIPT
#!/bin/bash
set -euo pipefail
set -x
# Change into a temporary directory so that the files all end up in one place
cd "$( mktemp -d -t "wireguard-XXXX" )"
# Dump the script to a file so we can debug it when things go wrong
cat "${BASH_SOURCE[0]}" > userdata.sh
GG="www.google.com"
# Wait for the network to be up before doing anything else
while ! ( curl $GG &> /dev/null ); do
  sleep 5
done
# Install wireguard, unbound, and other utilities
export DEBIAN_FRONTEND=noninteractive
U="unbound"
apt update &> /dev/null
apt install -q -y wireguard iptables-persistent $U $U-host net-tools &> /dev/null
# Generate keys
P="PrivateKey"
PK="PublicKey"
S="Server"
C="Client"
wg genkey | tee $S$P | wg pubkey > $S$PK
wg genkey | tee $C$P | wg pubkey > $C$PK
# Generate wireguard server configuration
W="wg0"
WG="$W.conf"
cat << SERVER > $WG
[Interface]
Address = #{server_subnet}
SaveConfig = true
$P = $( cat $S$P )
ListenPort = #{server_port}

[Peer]
$PK = $( cat $C$PK )
AllowedIPs = #{client_address}
SERVER
# Generate client configuration. We use a trick to find our public IP address:
# https://www.cyberciti.biz/faq/how-to-find-my-public-ip-address-from-command-line-on-a-linux/
cat << CLIENT > "client.conf"
[Interface]
Address = #{client_address}
$P = $( cat $C$P )
DNS = #{server_subnet[0..-4]}

[Peer]
$PK = $( cat $S$PK )
Endpoint = $( dig +short myip.opendns.com @resolver1.opendns.com ):#{server_port}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 21
CLIENT
# Enable wireguard service
chown -v root:root $WG
E="/etc/wireguard/$WG"
cp $WG $E
chmod -v 600 $E
wg-quick up $W
systemctl enable wg-quick@$W.service
# Enable IP forwarding
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/20-ipv4-forward.conf
sysctl -p
echo 1 > /proc/sys/net/ipv4/ip_forward
# Firewall rules
iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -p udp -m udp --dport #{server_port} -m conntrack --ctstate NEW -j ACCEPT
iptables -A INPUT -s #{server_subnet} -p tcp -m tcp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
iptables -A INPUT -s #{server_subnet} -p udp -m udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -i wg0 -o wg0 -m conntrack --ctstate NEW -j ACCEPT
iptables -t nat -A POSTROUTING -s #{server_subnet} -o eth0 -j MASQUERADE
# Save the rules
N="netfilter-persistent"
systemctl enable $N
$N save
# Download list of root DNS servers
curl -o /var/lib/$U/root.hints "https://www.internic.net/domain/named.cache"
# Create unbound configuration
cat << UNBOUND > /etc/$U/$U.conf.d/$WG
server:

  num-threads: 4

  #Enable logs
  verbosity: 1

  #list of Root DNS Server
  root-hints: "/var/lib/$U/root.hints"

  #Respond to DNS requests on all interfaces
  interface: 0.0.0.0
  max-udp-size: 3072

  #Authorized IPs to access the DNS Server
  access-control: 0.0.0.0/0                 refuse
  access-control: 127.0.0.1                 allow
  access-control: #{server_subnet}         allow

  #not allowed to be returned for public internet  names
  private-address: #{server_subnet}

  # Hide DNS Server info
  hide-identity: yes
  hide-version: yes

  #Limit DNS Fraud and use DNSSEC
  harden-glue: yes
  harden-dnssec-stripped: yes
  harden-referral-path: yes

  #Add an unwanted reply threshold to clean the cache and avoid when possible a DNS Poisoning
  unwanted-reply-threshold: 10000000

  #Have the validator print validation failures to the log.
  val-log-level: 1

  #Minimum lifetime of cache entries in seconds
  cache-min-ttl: 1800 

  #Maximum lifetime of cached entries
  cache-max-ttl: 14400
  prefetch: yes
  prefetch-key: yes
UNBOUND
# Set the correct permissions
chown -R $U:$U /var/lib/$U
# Disable and stop systemd-resolved
SS="systemd-resolved"
S="systemctl"
$S stop $SS
$S disable $SS
# Enable and restart unbound
$S enable $U
$S restart $U
# Verify that unbound is working
nslookup $GG. #{server_subnet[0..-4]}
# Copy the client configuration into a known place so we can get it with ssh
cp client.conf #{client_conf_location}
SETUPSCRIPT
# Initialize the client.
token = ENV['DO_TOKEN'] || (raise StandardError, "Provide digital ocean token with DO_TOKEN environment variable.")
client = DropletKit::Client.new(access_token: token)
# Grab the ssh keys assuming one of them is available locally and will let us log in.
ssh_keys = client.ssh_keys.all.map { |k| k.fingerprint }
# Dump the userdata script locally for debugging purposes.
File.open('/tmp/wireguard-userdata.sh', 'w') { |f| f.puts setup_script }
# Create a new droplet with the above inline script as the userdata script.
droplet = DropletKit::Droplet.new(
  names: ['wireguard-vpn'],
  image: 'ubuntu-19-10-x64',
  # Pick a random region or whatever is in DO_REGION environment variable
  region: ENV['DO_REGION'] || client.regions.all.map { |r| r.slug }.sample, 
  size: 's-1vcpu-1gb',
  ipv6: false,
  user_data: setup_script,
  tags: ['wireguard', 'vpn'],
  ssh_keys: ssh_keys
)
# Kick off the droplet creation process.
response = client.droplets.create_multiple(droplet).first
STDERR.puts "Waiting for IP address."
while (droplet = client.droplets.find(id: response.id)).networks.v4.empty?
  sleep 5
end
ip_address = droplet.networks.v4.first.ip_address
STDOUT.puts "Got IP address: #{ip_address}."
# Now we try to ssh in and grab the client configuration.
ssh_command = "if [[ ! -e #{client_conf_location} ]]; then echo 'waiting'; else echo 'done'; fi"
ssh_options = "-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=5"
ssh_prefix = "ssh #{ssh_options} root@#{ip_address}"
STDERR.puts "Waiting for configuration file to be created."
while (ready = `#{ssh_prefix} "#{ssh_command}" 2> /dev/null`.strip).empty? || ready[/^waiting$/]
  sleep 5
end
STDERR.puts "Configuration file created on the remote host so copying it to local host."
client_configuration = `#{ssh_prefix} "cat #{client_conf_location}" 2> /dev/null | tee #{client_conf_location}`.strip
# Restart the server.
STDERR.puts "Restarting VM just in case any changes require a restart."
`#{ssh_prefix} "shutdown -r now" &> /dev/null`
# Write out the configuration contents. Can be compared with /tmp/wireguard-client.conf. They should be the same.
File.open(File.basename(client_conf_location), 'w') { |f| f.puts client_configuration }