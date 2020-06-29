module SetupScript
  def self.[](client_conf_location:, server_conf_location:, server_subnet:, server_port:, client_address:)
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
apt update &> /dev/null
apt install -q -y wireguard iptables-persistent unbound unbound-host net-tools &> /dev/null
# Generate keys
P="PrivateKey"
PK="PublicKey"
S="Server"
C="Client"
wg genkey | tee $S$P | wg pubkey > $S$PK
wg genkey | tee $C$P | wg pubkey > $C$PK
# Generate wireguard server configuration
cat << SERVER > wg0.conf
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
chown -v root:root wg0.conf
E="#{server_conf_location}"
cp wg0.conf $E
chmod -v 600 $E
systemctl enable wg-quick@wg0.service
# Enable IP forwarding
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/20-ipv4-forward.conf
echo 1 > /proc/sys/net/ipv4/ip_forward
sysctl -p
# Download list of root DNS servers
curl -o /var/lib/unbound/root.hints "https://www.internic.net/domain/named.cache"
# Create unbound configuration
cat << UNBOUND > /etc/unbound/unbound.conf.d/wg0.conf
server:

  num-threads: 4

  #Enable logs
  verbosity: 1

  #list of Root DNS Server
  root-hints: "/var/lib/unbound/root.hints"

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
chown -R unbound:unbound /var/lib/unbound
# Disable and stop systemd-resolved
SS="systemd-resolved"
S="systemctl"
$S stop $SS
$S disable $SS
# Enable and restart unbound
$S enable unbound
$S restart unbound
# Verify that unbound is working
nslookup $GG. localhost
# Copy the client configuration into a known place so we can get it with ssh
cp client.conf #{client_conf_location}
SETUPSCRIPT
    reboot_script = <<-REBOOTSCRIPT
#!/bin/bash
set -euo pipefail
set -x
wg-quick up wg0
# Firewall rules
iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -p udp -m udp --dport #{server_port} -m conntrack --ctstate NEW -j ACCEPT
iptables -A INPUT -s #{server_subnet} -p tcp -m tcp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
iptables -A INPUT -s #{server_subnet} -p udp -m udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -i wg0 -o wg0 -m conntrack --ctstate NEW -j ACCEPT
iptables -t nat -A POSTROUTING -s #{server_subnet} -o eth0 -j MASQUERADE
# Save the rules
systemctl enable netfilter-persistent
netfilter-persistent save
REBOOTSCRIPT
    return setup_script, reboot_script
  end
end
