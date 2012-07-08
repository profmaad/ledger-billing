# -*- coding: utf-8 -*-
require 'rubygems'
require 'json'
require 'yaml'
require 'haml'
require 'data_mapper'
require 'uri'
require 'net/http'
require 'date'

require 'pp'

require 'sinatra/base'

DataMapper.setup(:default, "sqlite:///#{Dir.pwd}/development.sqlite")

# Models
require 'models/customer'

DataMapper.finalize
DataMapper.auto_upgrade!

class LedgerBilling < Sinatra::Base
  VERSION = "0.1"

  CONFIG_FILE = "ledger-billing.yml"

  PREFERENCES_SKELETON = {"accounts" => {}, "taxes" => {}, "personal" => {}}

  set :ledger_rest_uri, "http://127.0.0.1:3000/rest"
  set :database, "sqlite://development.sqlite"
  set :preferences, "preferences.yml"

  configure do |c|
    config = nil
    begin
      config = YAML.load_file(CONFIG_FILE)
      config = {} if (config.nil? or !config)
    rescue Exception => e
      config = {}
      puts "Failed to load config file: #{e}"
    end

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

    if @@preferences["extras"].nil?
      @preferences["extras"] = ""
    else
      @preferences["extras"] = YAML.dump(@@preferences["extras"]).lines.to_a[1..-1].join
    end

    @page_title = "Preferences"
    haml :preferences
  end
  post "/preferences/?" do
    @@preferences = params
    @@preferences["extras"] = YAML.load(@@preferences["extras"])
    @@preferences["extras"] = nil if @@preferences["extras"] == false
    pp @@preferences

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

    @transactions = get_transactions_for_customer(@customer.name)
    
    @page_title = @customer.name
    haml :customer
  end

  get "/invoice/?" do
    @invoices = get_invoices

    @invoices.each do |invoice|
      puts invoice["customer"]
      invoice["customer"] = Customer.find(:name => invoice["customer"]).first unless invoice["customer"].nil?
    end

    @page_title = "Invoices"
    haml :invoices_list
  end

  get "/invoice/:customer/:invoice" do
    @customer = Customer.get(params[:customer])
    @invoice = get_invoice(params[:customer], params[:invoice])
    pp @invoice

    @invoice["date"] = Date.strptime(@invoice["date"], '%Y/%m/%d')

    @billables = []
    @fees = []
    @vat = []
    @invoice["postings"].each do |p|
      case classify_posting(p)
      when :billable
        p["amount"] = p["amount"].gsub(/-/, "")

        if p["note"] =~ /@([0-9.,-]*)/ 
          p["rate"] = $1.to_f
          p["note"] = p["note"].gsub(/@[0-9.,-]*/, "")
        end
        
        if p["amount"][-1] == "s"
          p["hours"] = (get_amount(p["amount"])).to_f/3600.0
        else
          p["hours"] = 1
        end

        if p["hours"].nil? or p["rate"].nil?
          @billables << p
        else
          @fees << p
        end
      when :vat
        p["amount"] = p["amount"].gsub(/-/, "")        
        @vat << p
      end
    end

    @personal = @@preferences["personal"]
    @currency = @@preferences["currency"]
    @extras = @@preferences["extra"]

    pdf = render_pdf(erb :"custom/invoice")

    if pdf.nil?
      return [500, "Failed to generate PDF"]
    else
      filename = "Invoice #{@customer[:name]} #{params[:invoice]}.pdf"

      status 200
      headers "Content-Type" => "application/pdf", "Content-Disposition" => "attachment; filename=#{filename}"
      body pdf
    end
  end

  get "/tax/?" do
    @vat_received, @vat_paid = ledger_vat_balances

    @vat_received.map! { |r| r.gsub(/-/, "") }

    @page_title = "Tax Overview"
    haml :taxes
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
    def ledger_vat_balances
      received_account = construct_account_name(@@preferences["accounts"]["vat_received"])
      paid_account = construct_account_name(@@preferences["accounts"]["vat_paid"])

      received_balance = ledger_rest_do_request("balance", received_account)      
      paid_balance = ledger_rest_do_request("balance", paid_account)

      received = balance_report_get_total(received_balance).split("\n")
      paid = balance_report_get_total(paid_balance).split("\n")

      return [received, paid]
    end

    def classify_posting(posting)
      if posting["account"].include?(@@preferences["accounts"]["billable"])
        return :billable
      elsif posting["account"].include?(@@preferences["accounts"]["receivable"])
        return :receivable
      elsif posting["account"].include?(@@preferences["accounts"]["assets"])
        return :assets
      elsif posting["account"].include?(@@preferences["accounts"]["vat_received"])
        return :vat
      end
    end
    def posting_type_to_s(posting_type)
      return case posting_type
             when :billable then "Billable"
             when :receivable then "Receivable"
             when :assets then "Assets"
             when :vat then "VAT"
             else "Unknown"
             end
    end
    def merge_postings(postings)
      result = postings.inject(:+)

      return result.sort { |a,b| a["date"] <=> b["date"] }      
    end

    def customer_name_for_transaction(transaction)
      billables_account = construct_account_name(@@preferences["accounts"]["billable"])
      receivables_account = construct_account_name(@@preferences["accounts"]["receivable"])

      transaction["postings"].each do |posting|
        if posting["account"].start_with?(billables_account)
          return posting["account"][billables_account.length+1..-1]
        elsif posting["account"].start_with?(receivables_account)
          return posting["account"][receivables_account.length+1..-1]
        end
      end

      return nil
    end

    def get_invoices
      transactions = get_transactions
      
      invoices = transactions.reject { |t| t["type"] != :invoice }

      invoices.each do |invoice|
        invoice["customer"] = customer_name_for_transaction(invoice)
      end

      return invoices
    end
    def get_invoice(customer, invoice)
      transactions = get_transactions_for_customer(customer, invoice)

      transactions.each do |transaction|
        return transaction if transaction["type"] == :invoice
      end
      
      return nil
    end
    def get_transactions
      postings = ledger_rest_do_request("register", "")["postings"]
      transactions = reconstruct_transactions(postings)
      
      return transactions
    end
    def get_transactions_for_customer(customer, invoice=nil)
      query = "\":#{@customer.name}\""
      query += " and code \"#{invoice}\"" unless invoice.nil?

      postings = ledger_rest_do_request("register", query)["postings"]
      reverse_postings = ledger_rest_do_request("register", "-r "+query)["postings"]      

      transactions = reconstruct_transactions(merge_postings([postings, reverse_postings]))

      return transactions
    end
    def reconstruct_transactions(postings)
      transactions = []

      postings.each do |posting|
        if transactions.last.nil? or transactions.last["date"] != posting["date"] or transactions.last["payee"] != posting["payee"]
          transactions.last["type"] = classify_transaction(transactions.last) unless transactions.last.nil?

          transactions << { "date" => posting["date"], "payee" => posting["payee"], "code" => posting["code"], "postings" => [posting] }
        else
          transactions.last["postings"] << posting
        end
      end
      transactions.last["type"] = classify_transaction(transactions.last) unless transactions.last.nil?

      return transactions
    end
    def classify_transaction(transaction)
      postings = []

      transaction["postings"].each do |posting|
        postings << { :type => classify_posting(posting), :negative => amount_negative?(posting["amount"]) }
      end

      posting_types = postings.map { |p| p[:type] }.uniq

      if posting_types.size == 1 and posting_types[0] == :billable
        return :billables
      elsif posting_types.size.between?(2,3) and posting_types.include?(:billable) and posting_types.include?(:receivable)
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

    def render_pdf(src)
      pdf = nil
        
      in_tmpdir do |tmpdir|
        File.open(tmpdir+"/document.tex", "w") do |f|
          f.write(src)
        end

        system("cat #{tmpdir}/document.tex")

        render_successful = system("pdflatex -interaction=nonstopmode -output-directory=\"#{tmpdir}\" #{tmpdir}/document.tex")
        return nil unless render_successful          

        File.open(tmpdir+"/document.pdf", "rb") do |f|
          pdf = f.read
        end
      end

      return pdf
    end
    def texify_newlines(string)
      return nil unless string.respond_to?(:gsub)

      return string.gsub(/\n/, "\\\\\\\\")
    end
    def texify_string(string)
      return texify_newlines(string).gsub(/_/, "\\_")
    end

    def in_tmpdir
      path = File.expand_path "#{Dir.tmpdir}/#{Time.now.to_i}#{rand(1000)}/"
      FileUtils.mkdir_p(path)
      
      yield(path)
      
    ensure
      FileUtils.rm_rf(path) if File.exists?(path)
    end
  end
end
