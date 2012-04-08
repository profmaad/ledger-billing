# -*- coding: utf-8 -*-
require 'rubygems'
require 'json'
require 'yaml'
require 'haml'

require 'sinatra/base'

class LedgerBilling < Sinatra::Base
  VERSION = "0.0"

  CONFIG_FILE = "ledger-billing.yml"

  set :ledger_rest_uri, "http://127.0.0.1:9292/rest"

  configure do |c|
    config = YAML.load_file(CONFIG_FILE)
    puts "Failed to load config file" if config.nil?

    config.each do |key,value|
      set key.to_sym, value
    end
  end
end
