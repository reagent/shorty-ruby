ENV["APP_ENV"] ||= "development"

require "bundler"
Bundler.setup(:default, ENV["APP_ENV"])

require "sinatra"
require "pathname"
require "active_record"
require "rack/utils"
require "active_support/core_ext/hash"

root = Pathname.new(__FILE__).join("..").expand_path

if ENV["APP_ENV"] == "production"
  ActiveRecord::Base.establish_connection(ENV["DATABASE_URL"])

  sql = <<-SCHEMA
    CREATE TABLE IF NOT EXISTS links (
      id SERIAL PRIMARY KEY NOT NULL,
      url VARCHAR(2000) NOT NULL,
      url_hash CHAR(32) NOT NULL UNIQUE,
      code CHAR(6) NOT NULL UNIQUE,
      created_at TIMESTAMP NOT NULL DEFAULT (NOW() AT TIME ZONE 'UTC')
    );

    CREATE TABLE IF NOT EXISTS accesses (
      id SERIAL PRIMARY KEY NOT NULL,
      link_id INTEGER NOT NULL,
      referrer_url VARCHAR(255),
      user_agent VARCHAR(255),
      created_at TIMESTAMP NOT NULL DEFAULT (NOW() AT TIME ZONE 'UTC'),
      FOREIGN KEY (link_id) REFERENCES links(id) ON DELETE RESTRICT
    );
  SCHEMA
else
  ActiveRecord::Base.establish_connection({
    adapter:  "sqlite3",
    database: root.join(%{#{ENV["APP_ENV"]}.sqlite3})
  })

  sql = <<-SCHEMA
    CREATE TABLE IF NOT EXISTS links (
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
      url VARCHAR(2000) NOT NULL,
      url_hash CHAR(32) NOT NULL UNIQUE,
      code CHAR(6) NOT NULL UNIQUE,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE IF NOT EXISTS accesses (
      id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
      link_id INTEGER NOT NULL,
      referrer_url VARCHAR(255),
      user_agent VARCHAR(255),
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY (link_id) REFERENCES links(id)
    );
  SCHEMA
end

statements = sql.split(/;$/).map(&:strip).reject(&:blank?)
statements.each {|s| ActiveRecord::Base.connection.execute(s) }

class App < Sinatra::Base
  configure do
    set :markdown, layout_engine: :erb
    set :markdown, layout_options: {views: settings.root}
  end

  get "/" do
    markdown File.read("README.md"), layout: true
  end

  post "/short_link" do
    require_json

    data = JSON.parse(request.body.read) rescue {}
    shortener = Shortener.new(data)

    if link = shortener.shorten
      [200, LinkSerializer.new(link, base_uri: base_uri).to_json]
    else
      [400, ErrorsSerializer.new(shortener.errors).to_json]
    end
  end

  get %r{/(\w{6})} do |code|
    link = Link.find_by(code: code) || halt(404)

    link.accesses.create({
      referrer_url: request.referrer,
      user_agent:   request.user_agent
    })

    [301, {"Location" => link.url}, "301 Moved Permanently\n"]
  end

  get %r{/(\w{6})\+} do |code|
    require_json

    link = Link.find_by(code: code) || halt(404)

    [200, AccessesSerializer.new(link.accesses).to_json]
  end

  private

  def require_json
    halt(404) unless request.content_type == "application/json"
    headers "Content-Type" => "application/json"
  end

  def base_uri
    URI("#{request.scheme}://#{request.host_with_port}")
  end
end

# Models
class UrlValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    if !URLValidator.new(value).valid?
      record.errors[attribute] << (options[:message] || "is invalid")
    end
  end
end

class Link < ActiveRecord::Base
  has_many :accesses

  validates :url, presence: true, length: {maximum: 2000}
  validates :url, url: true, unless: :url_errors?
  validates :code, uniqueness: true

  validate :url_hash_is_unique, if: :url_hash?

  before_validation :assign_url_hash, if: :url_valid?

  def self.for_url(url)
    find_by(url_hash: URLHasher.hash(url))
  end

  private

  def url_errors?
    errors[:url].any?
  end

  def assign_url_hash
    self.url_hash = URLHasher.hash(url)
  end

  def url_valid?
    URLValidator.new(url).valid?
  end

  def url_hash_is_unique
    if self.class.where(url_hash: url_hash).any?
      errors.add(:url, "must be unique")
    end
  end
end

class Access < ActiveRecord::Base
  belongs_to :link

  default_scope { order(created_at: :desc) }
end

class Shortener
  include ActiveModel::Validations

  attr_accessor :long_url

  validates :long_url, presence: true, length: {maximum: 2000}
  validates :long_url, url: true, unless: :url_errors?

  def initialize(attributes = {})
    attributes.each do |key, value|
      setter_method_name = "#{key}="
      send(setter_method_name, value) if respond_to?(setter_method_name)
    end
  end

  def shorten
    existing_link || create_link if valid?
  end

  private

  def url_errors?
    errors[:long_url].any?
  end

  def existing_link
    Link.for_url(long_url)
  end

  def create_link
    Link.create(url: long_url, code: next_available_code).tap do |link|
      if !link.persisted?
        errors.add(:long_url, "could not be shortened") and return nil
      end
    end
  end

  def next_available_code
    code    = CodeGenerator.generate
    retries = 3

    until retries == 0 || Link.where(code: code).none? do
      code = CodeGenerator.generate
      retries -= 1
    end

    code
  end
end

# Serializers
class LinkSerializer
  def initialize(object, base_uri:)
    @object   = object
    @base_uri = base_uri
  end

  def as_json(*opts)
    {
      long_url:   @object.url,
      short_link: short_link.to_s
    }
  end

  private

  def short_link
    @base_uri.tap {|u| u.path = "/#{@object.code}" }
  end
end

class AccessesSerializer
  def initialize(accesses)
    @accesses = accesses
  end

  def as_json(*opts)
    {response: accesses}
  end

  private

  def accesses
    @accesses.map {|a| AccessSerializer.new(a) }
  end
end

class AccessSerializer
  def initialize(access)
    @access = access
  end

  def as_json(*opts)
    {
      time:       @access.created_at,
      referrer:   @access.referrer_url.presence || "none",
      user_agent: @access.user_agent.presence || "none"
    }
  end
end

class ErrorsSerializer
  def initialize(errors)
    @errors = errors
  end

  def as_json(*opts)
    {errors: keyed_messages}
  end

  private

  def keyed_messages
    @errors.messages.inject({}) {|m, (k,v)| m.merge(k => v.join(", ")) }
  end
end

# Utils
class URLHasher
  def self.hash(url)
    new(url).hash
  end

  def initialize(url)
    @url = url
  end

  def hash
    Digest::MD5.hexdigest(normalized_uri.to_s)
  end

  private

  def normalized_uri
    URI(@url).tap do |uri|
      uri.scheme = uri.scheme.downcase
      uri.host   = uri.host.downcase
      uri.path   = uri.path.downcase

      uri.query = reorder_params(uri.query) if uri.query.present?
    end
  end

  def reorder_params(parameter_list)
    params = Rack::Utils.parse_nested_query(parameter_list)
    sorted_params = Hash[params.sort {|a,b| a[0] <=> b[0] }]
    sorted_params.to_query
  end
end

class URLValidator
  HOSTNAME_REGEXP = %r{\A\S+\.\S+\Z}

  def initialize(url)
    @url = url
  end

  def valid?
    %w[http https].include?(uri.scheme) && uri.host =~ HOSTNAME_REGEXP
  end

  private

  def uri
    @uri ||= URI(@url.to_s)
  end
end

class CodeGenerator
  def self.generate
    SecureRandom.base64(9).gsub(/[^\w\d]+/, '')[0...6]
  end
end
