#!/usr/bin/env ruby
require 'uri'
require 'json'
require 'rest_client'
require 'data_mapper'
require 'twitter'
require 'nokogiri'
require 'securerandom'
require 'clockwork'

include Clockwork

every(30.seconds, 'Fetch messages') { fetch_messages }

class User
  include DataMapper::Resource
  property :id, Serial 
  property :readmill_id, Integer
  property :name, String
  property :access_token, String
  property :twitter_handle, String  
end

class Message
  include DataMapper::Resource
  property :id, Serial 
  property :last_id, String, :default => 1
end

DataMapper.finalize

DataMapper.setup(:default, (ENV["DATABASE_URL"] || {
  :adapter  => 'mysql',
  :host     => 'localhost',
  :username => 'root' ,
  :password => '',
  :database => 'tweetmill'}))

DataMapper.auto_upgrade!  

READMILL_CLIENT_ID = "3157dd6728aacd2cf93e3588893e9848"
READMILL_CLIENT_SECRET = "d2ddd931b979fcc461e677497f22bafc"
READMILL_REDIRECT = "http://tweetmill.herokuapp.com/callback/readmill"

Twitter.configure do |config|
  config.consumer_key = "F6fdEc2IEDr8ysrOXeXwA"
  config.consumer_secret = "c6WNSEgqndgoOW8RW9oP7jtgEjpWwflnQJMvdzYso"
  config.oauth_token = "541793455-CoteuIjFNcz6qSy7wwgswSrX1d2ooSDBJTDJfS1N"
  config.oauth_token_secret = "Gm1Zb46QFQ3nV8qeRt7L5mtsKOAbxG81eWyyqj8mT4"
end

def fetch_messages
  puts "Fetching new messages"
  
  last_message = Message.first_or_create({:id => 1})
  messages = Twitter.direct_messages({:since_id => last_message.last_id})
  unless messages.empty? 
    last_message.last_id = messages[0].id.to_s
    last_message.save!
    messages.reverse.each do |m|
      puts "New message arrived from #{m.sender.screen_name}: #{m.text}"
      decode_and_validate_message(m.text, m.sender.screen_name.downcase)
    end
  end
  puts "Done"
  return
end

def decode_and_validate_message(message, sender_screen_name)
  user = User.first({:twitter_handle => sender_screen_name})
  if user
    message = message.split(' ')
    if message.size > 1
      isbn = message.shift
      action = message.join(' ')
      
      respond(user, "Sorry, that doesn't look like a correct ISBN") and return unless isbn.size == 10 || isbn.size == 13
      
      post_update(user, isbn, action)
    end
  else
    Twitter.update("@#{sender_screen_name} Sorry, don't know who you are. Connect at http://tweetmill.herokuapp.com/")
  end
end

def post_update(user, isbn, action)
  reading_url = reading(user, isbn)
    
  case action
  when "interesting"
    if !reading_url.nil?
      if is_interesting?(reading_url, user)
        respond(user, "You've already marked this book as interesting, time to start reading!")
      else
        respond(user, "You are already reading this book (#{isbn}). Try highlighting or updating progress.")
      end
    else
      start_or_interesting_reading(user, isbn, 1)
    end
  when "start"
    if !reading_url.nil?
      if is_interesting?(reading_url, user)
        update_reading_state(user, reading_url, "start")
      else
        respond(user, "You are already reading this book (#{isbn}). Try highlighting or updating progress.")
      end
    else
      start_or_interesting_reading(user, isbn, 2)
    end
  when "finish", "abandon"
    if reading_url.nil? || is_interesting?(reading_url, user)
      respond(user, "You are not reading this book! Send: #{isbn} start")
    else
      update_reading_state(user, reading_url, action)
    end
  else
    respond(user, "You are not reading this book! Send: #{isbn} start") and return if reading_url.nil? || is_interesting?(reading_url, user)
    if progress_update(action)
      update_reading_progress(user, reading_url, progress_update(action))
    else
      if ((action[0] == '"' && action[-1] == '"') || (action[0] == "\u201C" && action[-1] == "\u201D"))
        share_highlight(user, reading_url, action[1..(action.size-2)])
      else
        respond(user, "Sorry, could not understand that...")
      end
    end
  end
end

def progress_update(action)
  begin
    percent = Integer(action)
    return percent.to_s
  rescue ArgumentError
    a = action.to_s.split('/')
    if a.size == 2
      begin
        pos = Integer(a[0])
        tot = Integer(a[1])
        return false unless Math.abs(pos) < Math.abs(tot)
        return Integer((pos.to_f/tot.to_f)*100).to_s
      rescue Exception => e
        #noop
      end
    end
  end

  return false
end

def share_highlight(user, reading_url, highlight)
  reading_url = "#{reading_url}/highlights"

  params = {
    :access_token => user.access_token,
    :client_id => READMILL_CLIENT_ID,
    :highlight => { :content => highlight,
                    :position => 0.0
                  }
  }
  
  begin  
    RestClient.post(reading_url, params)
    respond(user, "Nice highlight!")
  rescue RestClient::UnprocessableEntity
    respond(user, "Could not share highlight... Sorry :/")
  end
  
end

def update_reading_progress(user, reading_url, percent)
  reading_url = "#{reading_url}/pings"
    
  params = {
    :access_token => user.access_token,
    :client_id => READMILL_CLIENT_ID,
    :ping => { :identifier => SecureRandom.hex(2),
               :progress => (percent.to_f / 100.0)
          }
  }
  
  
  begin  
    RestClient.post(reading_url, params)
    respond(user, "Congrats, you just reached #{percent}%")
  rescue RestClient::UnprocessableEntity
    respond(user, "Could not update progress... Sorry :/")
  end
  
end

def update_reading_state(user, reading_url, action)
  
  state = case action
  when "start" then 2
  when "finish" then 3
  when "abandon" then 4
  end
  
  message = case action
  when "start" then "Enjoy your new book."
  when "finish" then "Congrats, you've just finished another book. Way to go!"
  when "abandon" then "Don't feel guilty, just pick up something more interesting."
  end
    
  params = {
    :access_token => user.access_token,
    :client_id => READMILL_CLIENT_ID,
    :reading => { :state => state }
  }
    
    begin
      RestClient.put(reading_url, params)
      respond(user, message)
    rescue RestClient::UnprocessableEntity
      respond(user, "Sorry, could not update your reading status...")
      
    end
end

def is_interesting?(reading_url, user)
  params = {
    :access_token => user.access_token,
    :client_id => READMILL_CLIENT_ID
  }
  resp = JSON.parse(RestClient.get(reading_url, :params => params).to_str) rescue nil
  resp['state'] == 1
end

def reading(user, isbn)
  title, author = book_info(isbn)
  params = {
    :access_token => user.access_token,
    :client_id => READMILL_CLIENT_ID,
    "q[isbn]" => isbn,
    "q[author]" => author,
    "q[title]" => title
  }
  
  begin 
    resp = RestClient.get(readmill_request("/users/#{user.readmill_id}/readings/exists"), :params => params)
    if resp.code == 200
      return resp.headers[:location].gsub("/users/#{user.readmill_id}", '')
    else
      return nil
    end
  rescue RestClient::ResourceNotFound
    return nil
  end
end

def book_info(isbn)
  params = {
    :access_key => "PA52FISS",
    :index1 => "isbn",
    :value1 => isbn
  }
  
  doc = Nokogiri::XML(RestClient.get("http://isbndb.com/api/books.xml", :params => params))
  
  if doc.root.elements[0]['total_results'] == "1"
    title = doc.root.elements[0].elements[0].elements[0].inner_text
    author = doc.root.elements[0].elements[0].elements[2].inner_text
    return title, author
  end
end

def start_or_interesting_reading(user, isbn, state)
  title, author = book_info(isbn)
  
  if title.nil? or author.nil?
    respond(user, "Could not find this book, sorry :/") and return
  end
  
  params = {
    :access_token => user.access_token,
    :client_id => READMILL_CLIENT_ID,
    :book => {
        :author => author,
        :isbn => isbn,
        :title => title
    }
  }
    
  resp = RestClient.post(readmill_request("/books"), params)    
  book_url = resp.headers[:location]
    
  params = {
    :access_token => user.access_token,
    :client_id => READMILL_CLIENT_ID,
    :reading => {
        :state => state,
        :private => "false",
        :title => title
    }
  }

  resp = RestClient.post(book_url + "/readings", params)    


  ok_message = case state
  when 1 then "Just marked a new book as interesting, well found!"
  when 2 then "Yay, you've started reading!"
  end
 
  fail_message = case state
  when 1 then "You already have this book."
  when 2 then "You're already reading this book."
  end 
  if resp.code == 201
    respond(user, ok_message)
  elsif resp.code == 422
    respond(user, fail_message)
  else
    respond(user, "Something went wrong :/")
  end 
end

def respond(user, message)
  puts "#{user.twitter_handle}: #{message}"
  begin
    Twitter.direct_message_create(user.twitter_handle, message)
  rescue Twitter::Error::Forbidden
    Twitter.update("@#{user.twitter_handle} #{message}")
  end
end

def readmill_request(endpoint)
  "http://api.readmill.com#{endpoint}"
end