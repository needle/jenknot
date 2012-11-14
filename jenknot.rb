#!/usr/bin/env ruby

require 'rubygems'
require 'yaml'
require 'httparty'
require 'commander/import'

program :name, 'jenknot'
program :version, '0.0.1'
program :description, 'an interface to dreadnot deployment API, primarily for use with jenkins'

@config = Hash.new

global_option('-c FILE','--config FILE',String,'Specify path to config file with credentials') {|file| @config.merge!(YAML.load_file(file)['config'])}
global_option('-f','--force','Force deployment even if the current revision matches the desired revision') {$force = true}

command :haystack do |c|
  c.description = 'deploy specified revision of haystack'
  c.syntax = 'haystack --revision GIT_REVISION [--region DREADNOT_REGION]'
  c.option '--revision REVISION_ID', String, 'git revision id to be deployed for haystack'
  c.option '--region REGION', String, 'dreadnot region to deploy to (defaults to \'all\')'
  c.action do |args, options|
    options.default :region => 'all'
    
    dreadnot = Dreadnot.new(@config['username'],@config['password'],@config['api'])
    
    current_revision = dreadnot.deployed_revision('haystack',options.region)
    
    if options.revision != current_revision or $force == true
      dreadnot.deploy_revision('haystack',options.region,options.revision)
    else
      puts "haystack revision #{options.revision} is already deployed, skipping"
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
    options.default :region => options.partner

    dreadnot = Dreadnot.new(@config['username'],@config['password'],@config['api'])
    
    current_revision = dreadnot.deployed_revision("#{options.partner}_core",options.partner)

    if options.revision != current_revision or $force == true
      dreadnot.deploy_revision("#{options.partner}_core",options.partner,options.revision)
    else
      puts "core revision #{options.revision} is already deployed for partner #{options.partner}, skipping"
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
    options.default :region => options.partner
   
    dreadnot = Dreadnot.new(@config['username'],@config['password'],@config['api'])
   
    current_revision = dreadnot.deployed_revision("#{options.partner}_assets",options.region)

    if options.revision != current_revision or $force == true
      dreadnot.deploy_revision("#{options.partner}_assets",options.partner,options.revision)
    else
      puts "revision #{options.revision} of #{options.partner}'s assets already deployed, skipping"
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
    response = self.class.post(uri,options)

    case response['name']
    when "DreadnotError","NotFoundError","StackLockedError"
      raise "Error deploying #{stack} in region #{region} @ #{revision}: " + response['name']
    else
      deploy_id = response['name']
      print "Deploying #{stack} in region #{region} @ #{revision} as deploy #{deploy_id}."

      until deploy_running?(stack,region,deploy_id) == false
        sleep 2
        print "."
      end

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

end