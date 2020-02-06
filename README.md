# wireguard-vpn

Automating wireguard setup and associated configuration for DNS and firewall rules.
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
$ DO_TOKEN="$YOUR_DO_TOKEN" $OTHER_OPTIONS bundle exec ruby do-wireguard-vpn.rb
```

Now wait a few minutes and the client configuration will be copied to a local file called `wireguard-client.conf`.
You can then import this file into your wireguard client and connect to the VPN.

----
regions: nyc1, sgp1, lon1, nyc3, ams3, fra1, tor1, sfo2, blr1