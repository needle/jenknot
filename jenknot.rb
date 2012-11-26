#!/usr/bin/env ruby

require 'yaml'
require 'httparty'
require 'commander/import'

program :name, 'jenknot'
program :version, '0.1.3'
program :description, 'an interface to dreadnot deployment API, primarily for use with jenkins'

@config = Hash.new

global_option('-e ENVIRONMENT','--environment ENVIRONMENT',String,'Specify the name of the target environment (defined in config file)') {|e| $env = e }

global_option('-c FILE','--config FILE',String,'Specify path to config file with credentials') do |file|
  raw_config = YAML.load_file(file)
  if $env.nil? or $env.empty?
    case raw_config.keys.count
    when 1
      @config.merge!(raw_config.first[1])
    else
      raise 'Error: your config file contains multiple environments but you have not specified which one to use'
    end
  else
    if raw_config.has_key?($env)
      @config.merge!(raw_config[$env])
    else
      raise "Error: could not find environment #{$env} in config file"
    end
  end

  unless @config['username'] and @config['api']
    raise 'Error: you must provide a valid username and API end point via config file'
  end

  while @config['password'].nil? or @config['password'].empty?
    @config['password'] = ask("Password:  ") { |q| q.echo = "*" }
  end
end

global_option('-f','--force','Force deployment even if the current revision matches the desired revision') {$force = true}
global_option('-n','--noop','Perform a dry run, describing which actions would have been taken if the command were run for real') {$noop = true}

command :show do |c|
  c.description = 'shows the latest revision known to dreadnot for specified component'
  c.option '--partner PARTNER', String, 'partner name (only useful for showing asset revisions)'
  c.option '--region REGION', String, 'dreadnot region to query'
  c.action do |args, options|
    dreadnot = Dreadnot.new(@config['username'],@config['password'],@config['api'])

    case args.first
    when "haystack"
      options.default :region => 'all'
      latest = dreadnot.latest_revision('haystack')
      deployed = dreadnot.deployed_revision('haystack',options.region)
      puts "Latest known revision for haystack is #{latest}"
      puts "Latest deployed revision for haystack is #{deployed}"
    when "core"
      options.default :region => options.partner
      latest = dreadnot.latest_revision("#{options.partner}_core")
      deployed = dreadnot.deployed_revision("#{options.partner}_core",options.partner)
      puts "Latest known core revision for partner #{options.partner} is #{latest}"
      puts "Latest deployed core revision for partner #{options.partner} is #{deployed}"
    when "assets"
      options.default :region => options.partner
      latest =  dreadnot.latest_revision("#{options.partner}_assets")
      deployed = dreadnot.deployed_revision("#{options.partner}_assets",options.partner)
      puts "Latest known asset revision for partner #{options.partner} is #{latest}"
      puts "Latest deployed asset revision for partner #{options.partner} is #{deployed}"
    end

  end
end

command :haystack do |c|
  c.description = 'deploy specified revision of haystack'
  c.syntax = 'haystack --revision GIT_REVISION [--region DREADNOT_REGION]'
  c.option '--revision REVISION_ID', String, 'git revision id to be deployed for haystack'
  c.option '--region REGION', String, 'dreadnot region to deploy to (defaults to \'all\')'
  c.action do |args, options|
    dreadnot = Dreadnot.new(@config['username'],@config['password'],@config['api'])
    
    options.default :region => 'all'
    options.default :revision => dreadnot.latest_revision('haystack')

    current_revision = dreadnot.deployed_revision('haystack',options.region)

    if options.revision != current_revision or $force == true
      puts "Info: would have deployed haystack revision #{options.revision} in region #{options.region}, but we are in noop mode" if $noop
      unless $noop
        unless dreadnot.deploy_revision('haystack',options.region,options.revision)
          raise "Fatal: deployment of haystack revision #{options.revision} in region #{options.region} failed"
        end
      end
    else
      puts "Error: haystack revision #{options.revision} is already deployed, skipping"
    end

  end
end

command :core do |c|
  c.description = 'deploy specified revision of core for a specified partner'
  c.syntax = 'core --revision GIT_REVISION --partner PARTNER'
  c.option '--rev','--revision REVISION_ID', String, 'git revision id to be deployed for core'
  c.option '-p', '--partner PARTNER', String, 'partner to deploy to'
  c.option '--region REGION', String, 'dreadnot region to deploy to (defaults to partner name)'
  c.action do |args, options|
    dreadnot = Dreadnot.new(@config['username'],@config['password'],@config['api'])

    options.default :region => options.partner
    options.default :revision => dreadnot.latest_revision("#{options.partner}_core")
    
    current_revision = dreadnot.deployed_revision("#{options.partner}_core",options.partner)

    if options.revision[0,7] != current_revision or $force == true
      puts "Info: would have deployed core revision #{options.revision} for partner #{options.partner}, but we are in noop mode" if $noop
      unless $noop
        unless dreadnot.deploy_revision("#{options.partner}_core",options.partner,options.revision)
          raise "Fatal: deployment of core revision #{options.revision} for partner #{options.partner} failed."
        end
      end
    else
      puts "Error: core revision #{options.revision} is already deployed for partner #{options.partner}, skipping"
   end

  end
end

command :assets do |c|
  c.description = "deploy specified revision of specified partner's core assets"
  c.syntax = 'assets --revision GIT_REVISION --partner PARTNER'
  c.option '--revision REVISION_ID', String, 'git revision id to be deployed'
  c.option '--partner PARTNER', String, 'partner assets to deploy'
  c.option '--region REGION', String, 'dreadnot region to deploy to (defaults to partner name)'
  c.action do |args, options|
    dreadnot = Dreadnot.new(@config['username'],@config['password'],@config['api'])

    options.default :region => options.partner
    options.default :revision => dreadnot.latest_revision("#{options.partner}_assets")

    current_revision = dreadnot.deployed_revision("#{options.partner}_assets",options.region)

    if options.revision != current_revision or $force == true
      puts "Info: would have deployed assets revision #{options.revision} for partner #{options.partner}, but we are in noop mode" if $noop
      unless $noop
        unless dreadnot.deploy_revision("#{options.partner}_assets",options.partner,options.revision)
          raise "Fatal: deployment of assets revision #{options.revision} for #{options.partner} partner assets failed."
        end
      end
    else
      puts "Error: revision #{options.revision} of #{options.partner}'s assets already deployed, skipping"
   end
  
  end
end

class Dreadnot

  include HTTParty

  def initialize(user,pass,api)
    @api = api
    @auth = {:username => user, :password => pass}
  end

  def base_uri
    HTTParty.normalize_base_uri(@api)
  end

  def get(uri, options={})
    options.merge!({:basic_auth => @auth, :base_uri => base_uri})
    response = self.class.get(uri, options)
  end

  def put(uri, options={})
    options.merge!({:basic_auth => @auth, :base_uri => base_uri})
    response = self.class.put(uri, options)
  end

  def post(uri, options={})
    options.merge!({:basic_auth => @auth, :base_uri => base_uri})
    response = self.class.post(uri, options)
  end

  def delete(uri, options={})
    options.merge!({:basic_auth => @auth, :base_uri => base_uri})
    response = self.class.delete(uri, options)
  end

  def deployed_revision(stack,region,options={})
    options.merge!({:basic_auth => @auth, :base_uri => base_uri})
    uri = "/stacks/#{stack}/regions/#{region}"
    response = self.class.get(uri,options)
    response['deployed_revision']
  end

  def latest_revision(stack,options={})
    options.merge!({:basic_auth => @auth, :base_uri => base_uri})
    uri = "/stacks/#{stack}"
    response = self.class.get(uri,options)
    response['latest_revision']
  end

  def deploy_revision(stack,region,revision,options={})
    options.merge!({:basic_auth => @auth, :base_uri => base_uri})
    options.merge!({:body => {'to_revision' => revision}})
    uri = "/stacks/#{stack}/regions/#{region}/deployments"

    begin
      response = self.class.post(uri,options)
    rescue => e
      puts "Error deploying #{stack} revision #{revision} to region #{region}: " + e.inspect
      raise
    end

    case response['name']
    when "DreadnotError","NotFoundError","StackLockedError"
      raise "Error deploying #{stack} in region #{region} @ #{revision}: " + response['name']
    else
      deploy_id = response['name']
      print "Deploying #{stack} in region #{region} @ #{revision} as deploy #{deploy_id}: "

      show_wait_spinner{
        until deploy_running?(stack,region,deploy_id) == false
          sleep 2
        end
      }

      if deploy_successful?(stack,region,deploy_id)
        puts "success!"
        return true
      else
        puts "fail!"
        return false
      end
    end
  end

  def deploy_status(stack,region,deploy_id,options={})
    options.merge!({:basic_auth => @auth, :base_uri => base_uri})
    uri = "/stacks/#{stack}/regions/#{region}/deployments/#{deploy_id}"
    response = self.class.get(uri,options)
  end

  def deploy_running?(stack,region,deploy_id)
    response = deploy_status(stack,region,deploy_id)
    if response['name'] == deploy_id.to_s
      response['finished'] ? false : true
    else
      raise "Error getting run status of deploy #{deploy_id}: #{response.inspect}"
    end
  end

  def deploy_successful?(stack,region,deploy_id)
    response = deploy_status(stack,region,deploy_id)
    if response['name'] == deploy_id.to_s
      response['success']
    else
      raise "Error getting success status of deploy #{deploy_id}: #{response.inspect}"
    end
  end

  private

  # courtesy http://stackoverflow.com/a/10263337/1118434
  def show_wait_spinner(fps=10)
    chars = %w[| / - \\]
    delay = 1.0/fps
    iter = 0
    spinner = Thread.new do
      while iter do  # Keep spinning until told otherwise
        print chars[(iter+=1) % chars.length]
        sleep delay
        print "\b"
      end
    end
  ensure
    yield.tap{       # After yielding to the block, save the return value
      iter = false   # Tell the thread to exit, cleaning up after itself…
      spinner.join   # …and wait for it to do so.
    }                # Use the block's return value as the method's
  end

end
