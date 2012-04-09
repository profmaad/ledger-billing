require 'data_mapper'

class Customer
  include DataMapper::Resource
  
  property :id, Serial
  property :name, String, :key => true
  property :address, Text  
end
