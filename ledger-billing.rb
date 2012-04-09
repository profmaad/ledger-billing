# -*- coding: utf-8 -*-
require 'rubygems'
require 'json'
require 'yaml'
require 'haml'
require 'data_mapper'
require 'uri'
require 'net/http'

require 'pp'

require 'sinatra/base'

DataMapper.setup(:default, "sqlite:///#{Dir.pwd}/development.sqlite")

# Models
require 'models/customer'

DataMapper.finalize
DataMapper.auto_upgrade!

class LedgerBilling < Sinatra::Base
  VERSION = "0.0"

  CONFIG_FILE = "ledger-billing.yml"

  PREFERENCES_SKELETON = {"accounts" => {}, "taxes" => {}, "personal" => {}}

  set :ledger_rest_uri, "http://127.0.0.1:9292/rest"
  set :database, "sqlite://development.sqlite"
  set :preferences, "preferences.yml"

  configure do |c|
    config = YAML.load_file(CONFIG_FILE)
    config = {} if (config.nil? or !config)
    puts "Failed to load config file" if config.nil?

    config.each do |key,value|
      set key.to_sym, value
    end

    if File.exists?(settings.preferences)
      @@preferences = YAML.load_file(settings.preferences)
    else
      @@preferences = PREFERENCES_SKELETON
    end
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

    @page_title = "Preferences"
    haml :preferences
  end
  post "/preferences/?" do
    @@preferences = params

    File.open(settings.preferences, 'w') do |file|
      YAML.dump(@@preferences, file)
    end

    redirect url("/preferences")
  end

  get "/customer" do
    billables_account = construct_account_name(@@preferences["accounts"]["billable"])
    receivables_account = construct_account_name(@@preferences["accounts"]["receivable"])

    balances = ledger_rest_do_request("balance", "-E --flat "+billables_account+" "+receivables_account)

    customers = {}
    balances["accounts"].each do |account, balance|
      if account.start_with?(billables_account)
        customer_name = account[billables_account.length+1..-1]
        type = :billable
      elsif account.start_with?(receivables_account)
        customer_name = account[receivables_account.length+1..-1]
        type = :receivable
      end

      if customers[customer_name].nil?
        customers[customer_name] = {:id => Customer.first_or_create(:name => customer_name).id }
      end

      case type
      when :billable
        customers[customer_name][:billable] = balance
      when :receivable
        customers[customer_name][:receivable] = balance
      end
    end
    @customers = customers
    
    @page_title = "Customers"
    haml :customer_list
  end

  get "/customer/:id" do
    @customer = Customer.get(params[:id])
    puts @customer.address.gsub(/\n/, '<br/>')

    @page_title = @customer.name
    haml :customer
  end

  helpers do
    def http_get_with_redirection(url)
      response = Net::HTTP.get_response(url)
      case response
      when Net::HTTPSuccess
        return response.body
      when Net::HTTPRedirection
        return http_get_with_redirection(URI.parse(response['location']))
      else
        response.error!
      end
    end

    def ledger_rest_do_request(resource, query)
      return JSON.parse(http_get_with_redirection(URI.parse("#{settings.ledger_rest_uri}/#{resource}?query=#{URI.escape(query)}")))
    end

    def construct_account_name(account)
      if account.start_with?(":")
        return @@preferences["accounts"]["prefix"]+account
      else
        return account
      end
    end
  end
end
