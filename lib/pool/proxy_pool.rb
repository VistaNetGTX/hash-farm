# -*- encoding : utf-8 -*-

require 'open-uri'
require 'nokogiri'
require 'core_extensions'
require "protocol/stratum"

require_relative './pool'
require_relative './worker_connection'

# using CoreExtensions

#
# The ProxyPool connect to an other distant pool.
# It forwards jobs to workers and shares to the distant pool.
# It acts as a big worker for the distant pool.
#
# Signals:
#   started
#   stopped
#   error(err)
#
class ProxyPool < Pool
  include Loggable
  include Listenable

  attr_accessor :version
  attr_reader :host, :port, :username
  attr_reader :notifications, :extra_nonce_1, :extra_nonce_2_size
  attr_reader :accepted_shares, :rejected_shares
  attr_reader :jobs_pdiff
  attr_reader :authentified

  #
  # ProxyPool.new( host, port, username, password )
  # ProxyPool.new( uri )
  # ProxyPool.new( url )
  #
  # ProxyPool.new( "middlecoin.com", 3333, "barbu", "toto" )
  # ProxyPool.new( "http://barbu:toto@middlecoin.com:3333" )
  # ProxyPool.new( url: "http://barbu:toto@middlecoin.com:3333" )
  # ProxyPool.new( url: "http://middlecoin.com:3333", user: "barbu", password: "toto" )
  # ProxyPool.new( "http://middlecoin.com:3333", "barbu", "toto" )
  # ProxyPool.new( URI("http://barbu:toto@middlecoin.com:3333") )
  # ProxyPool.new( URI("http://middlecoin.com:3333"), "barbu", "toto" )
  #
  def initialize( *args, **opt )
    @options = opt

    # Connection's options
    if args.size == 4
      @host, @port, @username, @password = *args
    elsif args.first.kind_of?( URI ) || opt[:uri]
      uri = args.first || opt[:uri]
      uri.user ||= args[1] || opt[:user]
      uri.password ||= args[2] || opt[:password]
      @host, @port, @username, @password = uri.host, uri.port, uri.user, uri.password
    elsif args.first.kind_of?( String ) || opt[:url]
      uri = URI( args.first ) || opt[:url]
      uri.user ||= args[1] || opt[:user]
      uri.password ||= args[2] || opt[:password]
      @host, @port, @username, @password = uri.host, uri.port, uri.user, uri.password
    else
      raise ArgumentError, "wrong number of argument"
    end

    # Pool.initialize
    super( opt[:name] || @host, opt )

    @proxy = Stratum::Client.new( @host, @port, back: @options[:back] )
    @authentified = false

    @jobs_pdiff = {}

    init_listeners
  end

  def init_listeners
    forward( @proxy, 'error' )
    on( 'error' ) do |error| ProxyPool.log.error( error.to_s ) end
    @proxy.on( 'connected' ) { authentify }
    @proxy.on( 'reconnected' ) {
      @authentified = false
      authentify
    }
    @proxy.on( 'disconnected' ) { @authentified = false }
  end

  def authentify
    @proxy.mining.on( 'notify' ) { |job| on_pool_notify( job ) }
    @proxy.mining.on( 'set_difficulty' ) { |diff| on_pool_set_difficulty( diff ) }

    @proxy.mining.subscribe( @version, @session_id ) do |resp|
      if resp.result?
        # If new session
        if resp.result[1] != @extra_nonce_1 || resp.result[2] != @extra_nonce_2_size
          @notifications, @extra_nonce_1, @extra_nonce_2_size = *resp.result
          if ! @notifications.kind_of?( Array ) || @notifications.size != 2
            ProxyPool.log.warn "[#{@host}] On subscribed, notifications = #{@notifications}"
          end
          @session_id = @notifications[0][1]
          @worker_extra_nonce_2_size = @extra_nonce_2_size > 1 ? (@extra_nonce_2_size / 2.0).floor : @extra_nonce_2_size
          @proxy_extra_nonce_2_size = @extra_nonce_2_size - @worker_extra_nonce_2_size
          ProxyPool.log.verbose "[#{@host}] subscribe : extra1=%s, extra2size=%d" % [@extra_nonce_1, @extra_nonce_2_size]
          # On a reconnect.
          @workers.each { |w| w.client.reconnect }
        end

        @proxy.mining.authorize( @username, @password ) do |resp|
          if resp.result? && resp.result
            @authentified = true
            pool_start # Call super.start
          elsif resp.result? # => resp.result != true
            emit( 'error', "not authorized" )
            stop
          else
            emit( 'error', "During authorization : #{resp.error}" )
            stop
          end
        end
      else
        emit( 'error', "During subscription : #{resp.error}" )
        stop
      end
    end
  end

  # Alias the Pool::start() method to call it later in authorize
  alias_method :pool_start, :start
  def start
    ProxyPool.log.info "[#{name}] Starting..."
    @proxy.connect
    # @proxy.on( 'connected' ) { authentify } in init_listeners
    # Rescue if fail to authentify.
    EM.add_timer( 30.seconds ) do
      if ! self.authentified
        log.error "[#{name}] Fail to authentify. Retry"
        stop
        EM.add_timer( 10.seconds ) do start end
      end
    end
    self
  end

  def stop
    ProxyPool.log.info "[#{name}] Stopping..."
    return self if ! started?
    @proxy.close
    super
    self
  end

  def notify_all_workers job=@last_job
    ProxyPool.log.verbose "[#{@host}] Notify #{@workers.size} workers with job #{job.id}."
    @workers.each do |worker|
      worker.notify( job )
    end
  end

  ##########################################################

  def on_pool_set_difficulty diff
    @next_diff = diff.to_f / 2**16
    ProxyPool.log.verbose "[#{@host}] New difficulty received : #{@next_diff}."
    @workers.each do |worker| adjust_difficulty( worker ) end
    # @workers.each do |worker| worker.set_difficulty @next_diff end
  end

  def on_pool_notify job
    ProxyPool.log.verbose "[#{@host}] New job received : #{job}."
    job.pool = @name
    # We notify workers as quickly as possible
    notify_all_workers( job )

    @last_job              = job
    @previous_jobs[job.id] = job
    @jobs_pdiff[job.id]    = @next_diff

    # 
    if job.clean # clean_jobs == true
      EM.cancel_timer( @clean_jobs_timer ) if @clean_jobs_timer
      # clean but keep last one for 1.second
      clean_previous_jobs(true)
      @clean_jobs_timer = EM.add_timer( 1.second ) do
        clean_previous_jobs(false)
        @clean_jobs_timer = nil
      end
    else
      @previous_jobs.shift if @previous_jobs.size > 50
      @jobs_pdiff.shift if @jobs_pdiff.size > 50
    end
  end

  ##########################################################

  def subscribe worker
    ProxyPool.log.debug "proxy pool subscribe"
    extra1, extra2size, diff, job = super
    pool_extra_nonce_2 = @proxy_extra_nonce_2_size > 0 ? rand( 256**@proxy_extra_nonce_2_size ).to_hex(@proxy_extra_nonce_2_size) : ''
    [@extra_nonce_1 + pool_extra_nonce_2, @worker_extra_nonce_2_size, diff, job]
  end

  def submit worker, req
    share = super
    if share.nil?
      req.respond false unless req.responded?
      return nil
    end

    # Check valid pool share
    _, job_id, extranonce2, ntime, nonce = *req.params
    pdiff = jobs_pdiff[job_id]
    # ProxyPool.log.debug "pdiff for #{job_id} = #{pdiff}"
    if share.match_difficulty( pdiff )
      extra_nonce_2 = worker.extra_nonce_1[@extra_nonce_1.size...@extra_nonce_1.size+@proxy_extra_nonce_2_size*2] # hex to byte
      extra_nonce_2 += share.extra_nonce_2
      pool_job = [@username, job_id, extra_nonce_2, ntime, nonce]
      ProxyPool.log.debug("[#{@name}] Send back pool job : #{pool_job}")
      @proxy.mining.submit( *pool_job ) do |resp|
        if resp.result?
          @accepted_shares += 1
          ProxyPool.log.info "[#{@name}]#{job_id}/#{share.ident}@#{worker.name} Accepted by pool"
          share.pool_result = true
        else
          @rejected_shares += 1
          ProxyPool.log.warn "[#{@name}]#{job_id}/#{share.ident}@#{worker.name} Not accepted by pool : #{resp.error}"
          share.pool_result = false
          share.reason = resp.error.to_s
        end
        if share.valid?
          share.save!
        else
          ProxyPool.log.error "[#{@name}] Share invalid before save ! #{share.to_json}"
        end
      end
    end

    share
  rescue ArgumentError => err
    ProxyPool.log.warn "[#{@name}][#{worker.name}] Fail on submit : #{err}\n" + err.backtrace[0...5].join("\n")
    nil
  rescue => err
    ProxyPool.log.error "[#{@name}] #{err}\n" + err.backtrace[0..5].join("\n")
    ProxyPool.log.error "worker=#{worker.inspect}"
    ProxyPool.log.error "share=#{share.inspect}"
    nil
  end

  ##########################################################

  # diff * 2**32 == le nombre de hash pour trouver un hash <= target
  # diff * 4 * 2**30 =~ diff * 4 * 10**9
  # diff * 4 =~ le nombre de Giga-hash pour trouver un share a cette diff
  # Compute diff
  # => retained diff
  def compute_diff( worker )
    [super, @next_diff].min
  end

  # def shares( since=Time.now-1.hour, untl=now )
  #   Share.where( pool: @name, pool_result: true ).where( ["created_at > ? AND created_at <= ?", since, untl] )
  # end

  # def hashrate2
  #   sum_diff = shares.map(&:difficulty).sum
  #   rate = (sum_diff / 1.hour * 2 ** 32).round
  # end
end
