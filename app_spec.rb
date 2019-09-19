ENV["APP_ENV"] ||= "test"

require "bundler"

Bundler.setup(:default, :test)

require "rspec"
require "rack/test"

require_relative "./app"

RSpec.configure do |config|
  config.around(:each) do |example|
    ActiveRecord::Base.connection.begin_transaction
    example.run
    ActiveRecord::Base.connection.rollback_transaction
  end
end

# Models
RSpec.describe Link do
  describe ".for_url" do
    it "returns nil when there are no URLs" do
      expect(described_class.for_url("http://example.org")).to be_nil
    end

    it "returns nil when the URL does not match" do
      Link.create!(url: "http://example.org", code: "OMGHIU")
      expect(described_class.for_url("http://google.com")).to be_nil
    end

    it "returns the link when the URL matches exactly" do
      link = Link.create!(url: "http://example.org", code: "OMGHIU")
      expect(described_class.for_url("http://example.org")).to eq(link)
    end

    it "returns a case-insensitive match" do
      link = Link.create!(url: "http://example.org", code: "OMGHIU")
      expect(described_class.for_url("HTTP://EXAMPLE.ORG")).to eq(link)
    end

    it "returns a match when parameters are the same but differently ordered" do
      link = Link.create!(url: "http://example.org?a=b&c=d", code: "OMGHIU")
      expect(described_class.for_url("http://example.org?c=d&a=b")).to eq(link)
    end
  end

  describe "validations" do
    it "requires the url to be present" do
      expect(subject).to_not be_valid
      expect(subject.errors[:url]).to eq(["can't be blank"])
    end

    it "requires the url to be valid" do
      subject = described_class.new(url: "bogus")

      expect(subject).to_not be_valid
      expect(subject.errors[:url]).to eq(["is invalid"])
    end

    it "limits the URL to 2000 characters" do
      subject = described_class.new(url: "a" * 2001)
      expect(subject).to_not be_valid

      expect(subject.errors[:url]).to eq(["is too long (maximum is 2000 characters)"])
    end

    it "requires a unique hash" do
      url = "http://example.test"
      described_class.create!(url: url, code: "OMGHIU")

      subject = described_class.new(url: url, code: "OTHER1")
      expect(subject).to_not be_valid
      expect(subject.errors[:url]).to eq(["must be unique"])
    end

    it "requires a unique code" do
      described_class.create!(url: "http://example.test", code: "OMGHIU")

      subject = described_class.new(code: "OMGHIU")
      expect(subject).to_not be_valid
      expect(subject.errors[:code]).to eq(["has already been taken"])
    end
  end

  describe "#save" do
    it "generates a hash of the URL" do
      url = "http://example.test"

      hasher = URLHasher.new(url)
      subject = described_class.new(url: url, code: "OMGHIU")

      expect { subject.save }.to change { subject.url_hash }.from(nil).to(hasher.hash)
    end
  end
end

RSpec.describe Shortener do
  describe ".new" do
    it "assigns attributes it understands" do
      subject = described_class.new(long_url: "ok")
      expect(subject.long_url).to eq("ok")
    end

    it "ignores attributes it does not understand" do
      expect { described_class.new(bogus: true) }.to_not raise_error
    end
  end

  describe "#shorten" do
    it "returns nil and sets errors if invalid" do
      expect(subject.shorten).to be_nil
      expect(subject.errors).to_not be_empty
    end

    it "creates a new link" do
      subject      = described_class.new(long_url: "http://example.test")
      created_link = subject.shorten

      expect(created_link.url).to eq("http://example.test")
      expect(created_link.code).to be_present
    end

    it "returns an existing link" do
      existing = Link.create!(url: "http://example.test", code: "OMGHIU")

      subject = described_class.new(long_url: "http://example.test")
      expect(subject.shorten).to eq(existing)
    end

    it "retries when encountering a duplicate code" do
      existing_code = "OMGHIU"

      Link.create!(url: "http://example.test", code: existing_code)

      # Cause CodeGenerator to create duplicate code
      allow(CodeGenerator).to \
        receive(:generate).with(no_args).and_return(existing_code, "ABCDEF")

      subject = described_class.new(long_url: "http://example2.test")

      created = subject.shorten
      expect(created.code).to_not eq(existing_code)
    end

    it "returns an error if it cannot generate a unique code" do
      existing_code = "OMGHIU"

      Link.create!(url: "http://example.test", code: existing_code)

      allow(CodeGenerator).to \
        receive(:generate).with(no_args).and_return(existing_code)

      subject = described_class.new(long_url: "http://example2.test")

      expect(subject.shorten).to be_nil
      expect(subject.errors[:long_url]).to eq(["could not be shortened"])
    end
  end

  describe "validations" do
    it "requires the url to be present" do
      expect(subject).to_not be_valid
      expect(subject.errors[:long_url]).to eq(["can't be blank"])
    end

    it "requires the url to be valid" do
      subject = described_class.new(long_url: "bogus")

      expect(subject).to_not be_valid
      expect(subject.errors[:long_url]).to eq(["is invalid"])
    end

    it "limits the URL to 2000 characters" do
      subject = described_class.new(long_url: "a" * 2001)
      expect(subject).to_not be_valid

      expect(subject.errors[:long_url]).to eq(["is too long (maximum is 2000 characters)"])
    end
  end
end

# Serializers
RSpec.describe LinkSerializer do
  describe "#as_json" do
    it "returns a representation of the link" do
      link = Link.new(url: "http://example.test", code: "OMGHIU")
      subject = described_class.new(link, base_uri: URI("http://example.org"))

      expect(subject.as_json).to eq({
        long_url:   "http://example.test",
        short_link: "http://example.org/OMGHIU"
      })
    end
  end
end

RSpec.describe ErrorsSerializer do
  describe "#as_json" do
    let(:errors) { ActiveModel::Errors.new(double) }

    it "returns a representation of errors" do
      errors.add(:attribute, "error message")
      errors.add(:other_attribute, "other error message")

      subject = described_class.new(errors)

      expect(subject.as_json).to eq({
        errors: {attribute: "error message", other_attribute: "other error message"}
      })
    end

    it "joins multiple error messages" do
      errors.add(:attribute, "first")
      errors.add(:attribute, "second")

      subject = described_class.new(errors)

      expect(subject.as_json).to eq({
        errors: {attribute: "first, second"}
      })
    end
  end
end

# Utils
RSpec.describe URLHasher do
  describe "#hash" do
    it "generates a different hash for two different URLs" do
      one = described_class.new("http://example.test")
      two = described_class.new("http://example.org")

      expect(one.hash).to_not eq(two.hash)
    end

    it "generates the same hash for the same URLs" do
      one = described_class.new("http://example.test")
      two = described_class.new("http://example.test")

      expect(one.hash).to eq(two.hash)
    end

    it "generates the same hash regardless of case" do
      one = described_class.new("http://example.test")
      two = described_class.new("HTTP://EXAMPLE.TEST")

      expect(one.hash).to eq(two.hash)
    end

    it "generates a different hash for trailing and no trailing slash" do
      one = described_class.new("http://example.test/path/")
      two = described_class.new("http://example.test/path")

      expect(one.hash).to_not eq(two.hash)
    end

    it "generates the same hash for the same params but ocurring in a different order" do
      one = described_class.new("http://example.test/?one=a&two=b")
      two = described_class.new("http://example.test/?two=b&one=a")

      expect(one.hash).to eq(two.hash)
    end
  end
end

RSpec.describe URLValidator do
  describe "#valid?" do
    it "is false when the value is nil" do
      subject = described_class.new(nil)
      expect(subject).to_not be_valid
    end

    it "is false if the value does not look like a valid URL" do
      subject = described_class.new("host")
      expect(subject).to_not be_valid
    end

    it "is false when the value is a hostname" do
      subject = described_class.new("google.com")
      expect(subject).to_not be_valid
    end

    it "is true when given an HTTP URL" do
      subject = described_class.new("http://google.com")
      expect(subject).to be_valid
    end

    it "is true when given an HTTPS URL" do
      subject = described_class.new("https://google.com")
      expect(subject).to be_valid
    end

    it "is false when given an unknown scheme" do
      subject = described_class.new("ftp://google.com")
      expect(subject).to_not be_valid
    end

    it "is false when the host doesn't look valid" do
      subject = described_class.new("http://host")
      expect(subject).to_not be_valid
    end
  end
end

RSpec.describe CodeGenerator do
  describe ".generate" do
    it "returns a code with a length of 6 characters" do
      expect(described_class.generate.length).to eq(6)
    end

    it "removes non-word and non-digit characters" do
      allow(SecureRandom).to receive(:base64).with(9).and_return("A/C+E1G=IJKL")
      expect(described_class.generate).to eq("ACE1GI")
    end
  end
end

# App
describe "API" do
  include Rack::Test::Methods

  def app
    App
  end

  def post(path, data = nil, as: nil)
    header("Content-Type", as) if as.present?
    payload = data.to_json if data.present? && data.is_a?(Hash)

    super(path, payload)
  end

  def parsed_body
    JSON.parse(last_response.body)
  end

  describe "POST /short_link" do
    it "returns a 404 when the content-type is not specified" do
      post "/short_link"

      expect(last_response.status).to eq(404)
    end

    it "responds with 'application/json'" do
      post "/short_link", nil, as: "application/json"
      expect(last_response.headers).to include("Content-Type" => "application/json")
    end

    it "returns a 400 if there is no payload" do
      post "/short_link", nil, as: "application/json"

      expect(last_response.status).to eq(400)
      expect(parsed_body).to eq({"errors" => {"long_url" => "can't be blank"}})
    end

    it "returns a 400 if the payload is invalid" do
      post "/short_link", {long_url: ""}, as: "application/json"

      expect(last_response.status).to eq(400)
      expect(parsed_body).to have_key("errors")
    end

    it "returns a 400 if the payload cannot be parsed" do
      post "/short_link", "{", as: "application/json"

      expect(last_response.status).to eq(400)
      expect(parsed_body).to include("errors")
    end

    it "creates a new short link when one doesn't exist" do
      expect {
        post "/short_link", {long_url: "http://google.com"}, as: "application/json"
      }.to change { Link.count }.by(1)

      expect(last_response).to be_ok
      expect(parsed_body).to include("long_url", "short_link")

      expect(parsed_body["long_url"]).to eq("http://google.com")
      expect(parsed_body["short_link"]).to match(%r{^http://example.org/[\w\d]{6}$})
    end

    it "returns an existing short link" do
      link = Link.create!(url: "http://example.test", code: "OMGHIU")

      post "/short_link", {long_url: "http://example.test"}, as: "application/json"

      expect(last_response).to be_ok
      expect(parsed_body).to eq({
        "long_url"   => "http://example.test",
        "short_link" => "http://example.org/OMGHIU"
      })
    end

    it "is case insensitive when returning an existing link" do
      link = Link.create!(url: "HTTP://EXAMPLE.TEST", code: "OMGHIU")

      post "/short_link", {long_url: "http://example.test"}, as: "application/json"

      expect(last_response).to be_ok
      expect(parsed_body).to eq({
        "long_url"   => "HTTP://EXAMPLE.TEST",
        "short_link" => "http://example.org/OMGHIU"
      })
    end
  end

  describe "GET /<code>" do
    it "returns a 404 when the code is not found" do
      get "/BOGUS1"

      expect(last_response.status).to eq(404)
    end

    it "permanently redirects when the code is found" do
      Link.create!(url: "http://example.test", code: "OMGHIU")

      get "/OMGHIU"

      expect(last_response.status).to eq(301)
      expect(last_response.headers["Location"]).to eq("http://example.test")
    end
  end
end
