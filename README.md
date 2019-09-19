# URL Shortener

A simple URL shortener that will create a unique shortcode for a URL. Making a
request for the shortcode will redirect a user to the desired target URL.

## Installation

```
git clone git@gist.github.com:3f489f3a153b7090380d0cd235cf6700.git ls
cd ls && bundle
```

You can run the server via rackup and it will listen on port 9292:

```
bundle exec rackup
```

## Features

The following features have been implemented:

* Requires a `Content-Type` of `application/json` when submitting a link to be
  shortened (will 404 on an unrecognized content type)
* Uniqueness checks for URLs take into account the GET parameters that are
  supplied without regard for order, the same parameters with a different order
  will result in a single shortcode
* There is a small chance that a generated shortcode will collide, but the
  application will attempt to re-try generation up to 3 times before returning
  an error to the user
* Requesting a shortcode URL (regardless of `Content-Type`) header will redirect
  the user to the source URL

## Examples

Creating a short link:

```
curl -s \
  -H "Content-Type: application/json" \
  -d '{"long_url":"http://google.com"}' \
  "http://localhost:9292/short_link" | python -m json.tool

{
    "long_url": "http://google.com",
    "short_link": "http://localhost:9292/ZtmLzB"
}
```

Creating a short link from a URL with the same GET parameters:

```
curl -s \
  -H "Content-Type: application/json" \
  -d '{"long_url":"http://example.org?one=a&two=b"}' \
  "http://localhost:9292/short_link" | python -m json.tool

{
    "long_url": "http://example.org?one=a&two=b",
    "short_link": "http://localhost:9292/w51n6o"
}

curl -s \
  -H "Content-Type: application/json" \
  -d '{"long_url":"http://example.org?two=b&one=a"}' \
  "http://localhost:9292/short_link" | python -m json.tool

{
    "long_url": "http://example.org?one=a&two=b",
    "short_link": "http://localhost:9292/w51n6o"
}
```

Requesting a shortcode:

```
curl -i "http://localhost:9292/w51n6o"
HTTP/1.1 301 Moved Permanently
Content-Type: text/html;charset=utf-8
Location: http://example.org?one=a&two=b
Content-Length: 22
X-XSS-Protection: 1; mode=block
X-Content-Type-Options: nosniff
X-Frame-Options: SAMEORIGIN
Connection: keep-alive
Server: thin

301 Moved Permanently
```

## Running Tests

Tests are located in `app_spec.rb` for all unit and integration tests.  Run
with:

```
bundle exec rspec
```
