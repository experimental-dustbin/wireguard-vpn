#!/bin/bash
# Token is required for most operations so export it.
export DO_TOKEN="$( cat ~/.do_token )"
# Grab the previous IDs because we are going to delete the old VPN servers.
previous_vpn_ids="$( bundle exec ruby do-wireguard-vpn.rb list | awk '{print $1}' | tee /tmp/wireguard-ids )"
for i in $previous_vpn_ids; do
  echo "Existing VPN that will be deleted: ${i}."
done
echo "Creating new VPN."
bundle exec ruby do-wireguard-vpn.rb create
echo "New VPN server created. Deleting old VPN servers."
for i in $previous_vpn_ids; do
  echo "Destroying VPN server: ${i}."
  bundle exec ruby do-wireguard-vpn.rb destroy --id "${i}"
done
