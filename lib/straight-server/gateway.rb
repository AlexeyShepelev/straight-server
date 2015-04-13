module StraightServer

  # This module contains common features of Gateway, later to be included
  # in one of the classes below.
  module GatewayModule

    # Temporary fix for straight server benchmarking
    @@redis = StraightServer::Config.redis[:connection] if StraightServer::Config.redis
    @@websockets = {}
    
    def fetch_transactions_for(address)
      try_adapters(@blockchain_adapters) { |b| b.fetch_transactions_for(address) }
    end

    class InvalidSignature           < Exception; end
    class InvalidOrderId             < Exception; end
    class CallbackUrlBadResponse     < Exception; end
    class WebsocketExists            < Exception; end
    class WebsocketForCompletedOrder < Exception; end
    class GatewayInactive            < Exception; end
    class NoWebsocketsForNewGateway  < Exception
      def message
        "You're trying to get access to websockets on a Gateway that hasn't been saved yet"
      end
    end
    class OrderCountersDisabled      < Exception
      def message
        "Please enable order counting in config file! You can do is using the following option:\n\n" +
        "  count_orders: true\n\n" +
        "and don't forget to provide Redis connection info by adding this to the config file as well:\n\n" +
        "  redis:\n" +
        "    host: localhost\n" +
        "    port: 6379\n" +
        "    db:   null\n"
      end
    end

    CALLBACK_URL_ATTEMPT_TIMEFRAME = 3600 # seconds


    ############# Initializers methods ########################################################
    # We have separate methods, because with GatewayOnDB they are called from #after_initialize
    # but in GatewayOnConfig they are called from #initialize intself.
    # #########################################################################################
    #
    def initialize(*attrs)
      @status_check_schedule  = Straight::GatewayModule::DEFAULT_STATUS_CHECK_SCHEDULE
      super
    end

    def initialize_exchange_rate_adapters
      @exchange_rate_adapters ||= []
      if self.exchange_rate_adapter_names
        self.exchange_rate_adapter_names.each do |adapter|
          begin
            @exchange_rate_adapters << Straight::ExchangeRate.const_get("#{adapter}Adapter").new
          rescue NameError => e 
            raise NameError, "No such adapter exists: Straight::ExchangeRate::#{adapter}Adapter"
          end
        end
      end
    end

    def initialize_blockchain_adapters
      @blockchain_adapters = [
        Straight::Blockchain::BlockchainInfoAdapter.mainnet_adapter
      ]
    end

    def initialize_callbacks
      # When the status of an order changes, we send an http request to the callback_url
      # and also notify a websocket client (if present, of course).
      @order_callbacks = [
        lambda do |order|
          StraightServer::Thread.new do
            send_callback_http_request     order
            send_order_to_websocket_client order
          end
        end
      ]
    end
    #
    ############# END OF Initializers methods ##################################################
 
    
    # Creates a new order and saves into the DB. Checks if the MD5 hash
    # is correct first.
    def create_order(attrs={})

      raise GatewayInactive unless self.active

      StraightServer.logger.info "Creating new order with attrs: #{attrs}"
      signature = attrs.delete(:signature)
      if !check_signature || sign_with_secret(attrs[:id]) == signature
        raise InvalidOrderId if check_signature && (attrs[:id].nil? || attrs[:id].to_i <= 0)
        order = order_for_keychain_id(
          amount:           attrs[:amount],
          keychain_id:      increment_last_keychain_id!,
          currency:         attrs[:currency],
          btc_denomination: attrs[:btc_denomination]
        )
        order.id         = attrs[:id].to_i if attrs[:id]
        order.data       = attrs[:data]    if attrs[:data]
        order.gateway    = self
        order.save
        self.save
        StraightServer.logger.info "Order #{order.id} created: #{order.to_h}"
        order
      else
        StraightServer.logger.warn "Invalid signature, cannot create an order for gateway (#{id})"
        raise InvalidSignature
      end
    end

    # Used to track the current keychain_id number, which is used by
    # Straight::Gateway to generate addresses from the pubkey. The number is supposed
    # to be incremented by 1. In the case of a Config file type of Gateway, the value
    # is stored in a file in the .straight directory.
    def increment_last_keychain_id!
      self.last_keychain_id += 1
      self.save
      self.last_keychain_id
    end

    def add_websocket_for_order(ws, order)
      raise WebsocketExists            unless websockets[order.id].nil?
      raise WebsocketForCompletedOrder unless order.status < 2
      StraightServer.logger.info "Opening ws connection for #{order.id}"
      ws.on(:close) do |event|
        websockets.delete(order.id)
        StraightServer.logger.info "Closing ws connection for #{order.id}"
      end
      websockets[order.id] = ws
      ws
    end

    def websockets
      raise NoWebsocketsForNewGateway unless self.id
      @@websockets[self.id]
    end

    def send_order_to_websocket_client(order)
      if ws = websockets[order.id]
        ws.send(order.to_json)
        ws.close
      end
    end

    def sign_with_secret(content, level: 1)
      result = content.to_s
      level.times do
        result = OpenSSL::HMAC.digest('sha256', secret, result).unpack("H*").first
      end
      result
    end

    def order_status_changed(order)
      statuses = Order::STATUSES.invert
      if StraightServer::Config.count_orders
        increment_order_counter!(statuses[order.old_status], -1) if order.old_status
        increment_order_counter!(statuses[order.status])
      end
      super
    end

    def order_counters(reload: false)
      return @order_counters if @order_counters && !reload
      @order_counters = {
        new:         get_order_counter(:new),
        unconfirmed: get_order_counter(:unconfirmed),
        paid:        get_order_counter(:paid),
        underpaid:   get_order_counter(:underpaid),
        overpaid:    get_order_counter(:overpaid),
        expired:     get_order_counter(:expired)
      }
    end

    def get_order_counter(counter_name)
      raise OrderCountersDisabled unless StraightServer::Config.count_orders
      @@redis.get("#{StraightServer::Config.redis[:prefix]}:gateway_#{id}:#{counter_name}_orders_counter").to_i || 0
    end

    def increment_order_counter!(counter_name, by=1)
      raise OrderCountersDisabled unless StraightServer::Config.count_orders
      @@redis.incrby("#{StraightServer::Config.redis[:prefix]}:gateway_#{id}:#{counter_name}_orders_counter", by)
    end

    private

      # Tries to send a callback HTTP request to the resource specified
      # in the #callback_url. If it fails for any reason, it keeps trying for an hour (3600 seconds)
      # making 10 http requests, each delayed by twice the time the previous one was delayed.
      # This method is supposed to be running in a separate thread.
      def send_callback_http_request(order, delay: 5)
        return if callback_url.nil?

        StraightServer.logger.info "Attempting to send request to the callback url for order #{order.id} to #{callback_url}..."

        # Composing the request uri here
        signature = self.check_signature ? "&signature=#{sign_with_secret(order.id, level: 2)}" : ''
        data      = order.data           ? "&data=#{order.data}"                                : ''
        uri       = URI.parse(callback_url + '?' + order.to_http_params + signature + data)

        begin
          response = Net::HTTP.get_response(uri)
          order.callback_response = { code: response.code, body: response.body }
          order.save
          raise CallbackUrlBadResponse unless response.code.to_i == 200
        rescue Exception => e
          if delay < CALLBACK_URL_ATTEMPT_TIMEFRAME
            sleep(delay)
            send_callback_http_request(order, delay: delay*2)
          else
            StraightServer.logger.warn "Callback request for order #{order.id} failed, see order's #callback_response field for details"
          end
        end
        
        StraightServer.logger.info "Callback request for order #{order.id} performed successfully"
      end

  end

  # Uses database to load and save attributes
  class GatewayOnDB < Sequel::Model(:gateways)

    include Straight::GatewayModule
    include GatewayModule
    plugin :timestamps, create: :created_at, update: :updated_at
    plugin :serialization, :marshal, :exchange_rate_adapter_names
    plugin :serialization, :marshal
    plugin :after_initialize

    def self.find_by_hashed_id(s)
      self.where(hashed_id: s).first
    end

    def before_create
      super
      encrypt_secret
    end

    def after_create
      @@websockets[self.id] = {}
      update(hashed_id: OpenSSL::HMAC.digest('sha256', Config.server_secret, self.id.to_s).unpack("H*").first)
    end

    def after_initialize
      @@websockets[self.id] ||= {} if self.id
      initialize_callbacks
      initialize_exchange_rate_adapters
      initialize_blockchain_adapters
    end
    
    # We cannot allow to store gateway secret in a DB plaintext, this would be completetly unsecure.
    # Althougth we use symmetrical encryption here and store the encryption key in the
    # server's in a special file (~/.straight/server_secret), which in turn can also be stolen,
    # this is still marginally better than doing nothing.
    #
    # Also, server admnistrators now have the freedom of developing their own strategy
    # of storing that secret - it doesn't have to be stored on the same machine.
    def secret
      decrypt_secret
    end

    def self.find_by_id(id)
      self[id]
    end

    private

      def encrypt_secret
        cipher           = OpenSSL::Cipher::AES.new(128, :CBC)
        cipher.encrypt
        cipher.key       = OpenSSL::HMAC.digest('sha256', 'nonce', Config.server_secret).unpack("H*").first[0,16]
        cipher.iv        = iv = OpenSSL::HMAC.digest('sha256', 'nonce', "#{self.id}#{Config.server_secret}").unpack("H*").first[0,16]
        encrypted        = cipher.update(self[:secret]) << cipher.final()
        base64_encrypted = Base64.strict_encode64(encrypted).encode('utf-8') 
        result           = "#{iv}:#{base64_encrypted}"
        
        # Check whether we can decrypt. It should not be possible to encrypt the
        # gateway secret unless we are sure we can decrypt it.
        if decrypt_secret(result) == self[:secret]
          self.secret = result
        else
          raise "Decrypted and original secrets don't match! Cannot proceed with writing the encrypted gateway secret."
        end
      end

      def decrypt_secret(encrypted_field=self[:secret])
        decipher      = OpenSSL::Cipher::AES.new(128, :CBC)
        iv, encrypted = encrypted_field.split(':')
        decipher.decrypt
        decipher.key  = OpenSSL::HMAC.digest('sha256', 'nonce', Config.server_secret).unpack("H*").first[0,16]
        decipher.iv   = iv
        decipher.update(Base64.decode64(encrypted)) + decipher.final
      end

  end

  # Uses a config file to load attributes and a special _last_keychain_id file
  # to store last_keychain_id
  class GatewayOnConfig

    include Straight::GatewayModule
    include GatewayModule

    # This is the key that allows users (those, who use the gateway,
    # online stores, for instance) to connect and create orders.
    # It is not used directly, but is mixed with all the params being sent
    # and a MD5 hash is calculted. Then the gateway checks whether the
    # MD5 hash is correct.
    attr_accessor :secret

    # This is used to generate the next address to accept payments
    attr_accessor :last_keychain_id

    # If set to false, doesn't require an unique id of the order along with
    # the signed md5 hash of that id + secret to be passed into the #create_order method.
    attr_accessor :check_signature

    # A url to which the gateway will send an HTTP request with the status of the order data
    # (in JSON) when the status of the order is changed. The response should always be 200,
    # otherwise the gateway will awesome something went wrong and will keep trying to send requests
    # to this url according to a specific shedule.
    attr_accessor :callback_url

    # This will be assigned the number that is the order in which this gateway follows in
    # the config file.
    attr_accessor :id

    attr_accessor :exchange_rate_adapter_names
    attr_accessor :orders_expiration_period
   
    # This affects whether it is possible to create a new order with the gateway.
    # If it's set to false, then it won't be possible to create a new order, but
    # it will keep checking on the existing ones.
    attr_accessor :active

    def self.find_by_hashed_id(s)
      self.find_by_id(s)
    end

    def initialize
      initialize_callbacks
      initialize_exchange_rate_adapters
      initialize_blockchain_adapters
    end

    # Because this is a config based gateway, we only save last_keychain_id
    # and nothing more.
    def save
      save_last_keychain_id!
    end

    # Loads last_keychain_id from a file in the .straight dir.
    # If the file doesn't exist, we create it. Later, whenever an attribute is updated,
    # we save it to the file.
    def load_last_keychain_id!
      @last_keychain_id_file ||= StraightServer::Initializer::ConfigDir.path + "/#{name}_last_keychain_id"
      if File.exists?(@last_keychain_id_file)
        self.last_keychain_id = File.read(@last_keychain_id_file).to_i
      else
        self.last_keychain_id = 0
        save
      end
    end

    def save_last_keychain_id!
      @last_keychain_id_file ||= StraightServer::Initializer::ConfigDir.path + "/#{name}_last_keychain_id"
      File.open(@last_keychain_id_file, 'w') {|f| f.write(last_keychain_id) }
    end

    # This method is a replacement for the Sequel's model one used in DB version of the gateway
    # and it finds gateways using the index of @@gateways Array.
    def self.find_by_id(id)
      @@gateways[id.to_i-1]
    end

    # This will later be used in the #find_by_id. Because we don't use a DB,
    # the id will actually be the index of an element in this Array. Thus,
    # the order in which gateways follow in the config file is important.
    @@gateways = []

    # Create instances of Gateway by reading attributes from Config
    i = 0
    StraightServer::Config.gateways.each do |name, attrs|
      i += 1
      gateway = self.new
      gateway.pubkey                         = attrs['pubkey']
      gateway.confirmations_required         = attrs['confirmations_required'].to_i
      gateway.order_class                    = attrs['order_class']
      gateway.secret                         = attrs['secret']
      gateway.check_signature                = attrs['check_signature']
      gateway.callback_url                   = attrs['callback_url']
      gateway.default_currency               = attrs['default_currency']
      gateway.orders_expiration_period       = attrs['orders_expiration_period']
      gateway.active                         = attrs['active']
      gateway.name                     = name
      gateway.id                       = i
      gateway.exchange_rate_adapter_names = attrs['exchange_rate_adapters']
      gateway.initialize_exchange_rate_adapters
      gateway.load_last_keychain_id!
      @@websockets[i] = {}
      @@gateways << gateway
    end

  end

  # It may not be a perfect way to implement such a thing, but it gives enough flexibility to people
  # so they can simply start using a single gateway on their machines, a gateway which attributes are defined
  # in a config file instead of a DB. That way they don't need special tools to access the DB and create
  # a gateway, but can simply edit the config file.
  Gateway = if StraightServer::Config.gateways_source == 'config'
    GatewayOnConfig
  else
    GatewayOnDB
  end

end
