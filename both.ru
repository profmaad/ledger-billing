$: << "."

require 'ledger-billing.rb'
require '../ledger-rest/ledger-rest.rb'

run Rack::URLMap.new( "/billing" => LedgerBilling.new, "/rest" => LedgerRest.new )
