require 'sqlite3'

class DB
  # The model/view we have of the Droplet.
  class Droplet
    attr_reader :droplet_id
    @@ssh_options = "-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=5".freeze
    def initialize(response, client, db)
      @response, @client, @db = response, client, db
      @db.execute(
        "insert into vm (id, ip, region, server_configuration, client_configuration) values (?, ?, ?, ?, ?)",
        [@droplet_id = response.id, '', @region = response.region.slug, '', '']
      )
    end
    def ssh_command(command, postfix)
      `ssh #@@ssh_options root@#{ip_address} "#{command}" #{postfix}`
    end
    def ip_address=(address)
      @ip_address = address
      @db.execute(
        "update vm set ip = ? where id = ?",
        [address, @droplet_id]
      )
    end
    def ip_address
      @ip_address ||= @db.get_first_value("select ip from vm where id = ?", [@droplet_id])
    end
    def client_configuration=(config)
      @client_configuration = config
      @db.execute(
        "update vm set client_configuration = ? where id = ?",
        [config, @droplet_id]
      )
    end
    def client_configuration
      @client_configuration ||= @db.get_first_value("select client_configuration from vm where id = ?", [@droplet_id])
    end
    def server_configuration=(config)
      @server_configuration = config
      @db.execute(
        "update vm set server_configuration = ? where id = ?",
        [config, @droplet_id]
      )
    end
    def server_configuration
      @server_configuration ||= @db.get_first_value("select server_configuration from vm where id = ?", [@droplet_id])
    end
    def ready?
      if !(@droplet = @client.droplets.find(id: @droplet_id)).networks.v4.empty?
        self.ip_address = @droplet.networks.v4.first.ip_address
      end
    end
  end
  def initialize
    @db = SQLite3::Database.new("wireguard-vpn.db")
    @db.execute <<-SQL
      create table if not exists vm (
        id int primary key not null,
        ip string not null,
        region string not null,
        server_configuration string not null,
        client_configuration string not null
      );
SQL
  end
  def delete(i)
    @db.execute(
      "delete from vm where id = ?",
      [i]
    )
  end
  def configuration(i)
    @db.get_first_value("select client_configuration from vm where id = ?", [i])
  end
  def list
    data = []
    @db.execute(
      "select id, ip, region from vm"
    ) do |row|
      data << row.join(' | ')
    end
    data.join("\n")
  end
  def close
    @db.close
  end
  def new_droplet(response, client)
    Droplet.new(response, client, @db)
  end
end