# -*- coding: utf-8 -*-
require 'rubygems'
require 'json'
require 'yaml'
require 'haml'
require 'data_mapper'

require 'sinatra/base'

class LedgerBilling < Sinatra::Base
  VERSION = "0.0"

  CONFIG_FILE = "ledger-billing.yml"

  PREFERENCES_SKELETON = {"accounts" => {}, "taxes" => {}, "personal" => {}}

  set :ledger_rest_uri, "http://127.0.0.1:9292/rest"
  set :database, "sqlite://development.sqlite"
  set :preferences, "preferences.yml"

  configure do |c|
    config = YAML.load_file(CONFIG_FILE)
    puts "Failed to load config file" if config.nil?

    config.each do |key,value|
      set key.to_sym, value
    end

    if File.exists?(settings.preferences)
      @@preferences = YAML.load_file(settings.preferences)
    else
      @@preferences = PREFERENCES_SKELETON
    end

    if development?
      DataMapper::Logger.new($stdout, :debug)
    end
    DataMapper.setup(:default, settings.database)
  end

  get "/" do
    redirect url("/dashboard")
  end
  
  get "/dashboard/?" do
    @page_title = "Dashboard"
    haml :dashboard
  end

  get "/preferences/?" do
    @preferences = @@preferences
    puts @preferences

    @page_title = "Preferences"
    haml :preferences
  end
end
