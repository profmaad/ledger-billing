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
    @billables, @receivables = ledger_customer_balances(@customer.name)
    @transactions = reconstruct_transactions(ledger_rest_do_request("register", "\":#{@customer.name}\"")["postings"])

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
    def ledger_customer_balances(customer_name)
      billables_account = '"'+construct_account_name(@@preferences["accounts"]["billable"])+":"+customer_name+'"'
      receivables_account = '"'+construct_account_name(@@preferences["accounts"]["receivable"])+":"+customer_name+'"'
      
      billable_balances = ledger_rest_do_request("balance", billables_account)
      receivable_balances = ledger_rest_do_request("balance", receivables_account)

      billables = balance_report_get_total(billable_balances).split("\n")
      receivables = balance_report_get_total(receivable_balances).split("\n")

      return [billables, receivables]
    end

    def classify_posting(posting)
      if posting["account"].include?(@@preferences["accounts"]["billable"])
        return :billable
      elsif posting["account"].include?(@@preferences["accounts"]["receivable"])
        return :receivable
      elsif posting["account"].include?(@@Preferences["accounts"]["assets"])
        return :assets
      end
    end
    def posting_type_to_s(posting_type)
      return case posting_type
             when :billable then "Billable"
             when :receivable then "Receivable"
             when :assets then "Assets"
             else "Unknown"
             end
    end

    def reconstruct_transactions(postings)
      transactions = []

      postings.each do |posting|
        if transactions.last.nil? or transactions.last[:date] != posting["date"] or transactions.last[:payee] != posting["payee"]
          transactions.last[:type] = classify_transaction(transactions.last) unless transactions.last.nil?

          transactions << { :date => posting["date"], :payee => posting["payee"], :postings => [posting] }
        else
          transactions.last[:postings] << posting
        end
      end
      transactions.last[:type] = classify_transaction(transactions.last) unless transactions.last.nil?

      return transactions
    end
    def classify_transaction(transaction)
      postings = []

      transaction[:postings].each do |posting|
        postings << { :type => classify_posting(posting), :negative => amount_negative?(posting["amount"]) }
      end

      posting_types = postings.map { |p| p[:type] }.uniq

      if posting_types.size == 1 and posting_types[0] == :billable
        return :billables
      elsif posting_types.size == 2 and posting_types.include?(:billable) and posting_types.include?(:receivable)
        return :invoice
      elsif posting_types.size == 2 and posting_types.include?(:receivable) and posting_types.include?(:assets)
        return :payment
      else
        return nil
      end
    end
    def transaction_type_to_s(transaction_type)
      return case transaction_type
             when :billables then "Billables"
             when :invoice then "Invoice"
             when :payment then "Payment"
             else "Unknown"
             end
    end

    def balance_report_get_total(report)
      if report["total"].nil?
        return report["accounts"].shift[1] unless report["accounts"].empty?
        return ""
      else
        return report["total"]
      end      
    end
    def get_amount(amount_string)
      return amount_string.split("").reject{|s| !"-0123456789.,".include?(s) }.join("").to_f
    end
    def split_amount(amount_string)
      amount = ""
      currency = ""

      amount_string.each_char do |c|
        if c.strip.empty?
          next
        elsif "-0123456789.,".include?(c)
          amount += c
        else
          currency += c
        end
      end

      return [currency, amount.to_f]
    end
    def sum_amounts(amounts)
      sums = {}
      
      amounts.each do |s|
        s.split("\n").each do |amount_string|
          currency, amount = split_amount(amount_string)
          
          sums[currency] = 0.0 if sums[currency].nil?
          
          sums[currency] += amount
        end
      end
    end
    def amount_negative?(amount)
      if amount.class == String
        return get_amount(amount) < 0
      else
        return amount < 0
      end
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
