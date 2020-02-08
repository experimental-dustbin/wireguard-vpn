# wireguard-vpn

Automated wireguard setup and configuration.
Credit goes to [Chrispus Kamau](https://github.com/iamckn) over
at [cnk.io](https://www.ckn.io/blog/2017/11/14/wireguard-vpn-typical-setup/) for providing the instructions.

Make sure you have at least one SSH key in your SSH agent that will allow you to log into the newly
created DigitalOcean VM. We need to run a few commands to copy over the client configuration that's why we need
SSH access. Currently we use `'s-1vcpu-1gb'` for size in a random region
(or `$DO_REGION`) with Ubuntu 19.10 (`'ubuntu-19-10-x64'`) as the base image.

To create the DigitalOcean VPN

```
$ git clone git@github.com:experimental-dustbin/wireguard-vpn.git
$ cd wireguard-vpn
$ bundle
$ [DO_TOKEN="$YOUR_DO_TOKEN"] [DO_REGION="$REGION_SLUG"] bundle exec ruby do-wireguard-vpn.rb create
```

Now wait a few minutes and the client configuration will be copied to a local file called `wireguard-client.conf`.
You can then import this file into your wireguard client and connect to the VPN.

The other actions that you can perform are `list` (for listing all the running VMs/VPNs),
`destroy --id $id` (for destroying the VM), and `configuration --id $id` (for getting the client
configuration associated with the given VM).

Here's an example transcript
```
$ DO_TOKEN=$TOKEN bundle exec ruby do-wireguard-vpn.rb create
Waiting for IP address.
Got IP address: 165.227.47.17.
Waiting for configuration file to be created.
Configuration file created on the remote host so copying it to local host.
Restarting VM just in case any changes require a restart.
```
```
$ DO_TOKEN=$TOKEN bundle exec ruby do-wireguard-vpn.rb list
179491591 | 165.227.47.17 | tor1
```
```
$ DO_TOKEN=$TOKEN bundle exec ruby do-wireguard-vpn.rb configuration --id 179491591
[Interface]
Address = 10.200.200.2/32
PrivateKey = * secret *
DNS = 10.200.200.1

[Peer]
PublicKey = /xm9moHo4gV1z7kSqCWqbaH4ODYOWDb12jKg8pN7+i4=
Endpoint = 165.227.47.17:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 21
```
```
$ DO_TOKEN=$TOKEN bundle exec ruby do-wireguard-vpn.rb destroy --id 179491591
```
----
regions: nyc1, sgp1, lon1, nyc3, ams3, fra1, tor1, sfo2, blr1