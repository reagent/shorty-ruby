# URL Shortener

A simple URL shortener that will create a unique shortcode for a URL. Making a
request for the shortcode will redirect a user to the desired target URL.

You can try it out for yourself:

```
curl -s -H "Content-Type: application/json" \
  -d '{"long_url":"https://github.com/reagent"}' \
  "http://shorty-ruby.herokuapp.com/short_link" | python -m json.tool
```

## Installation

```
git clone git@github.com:reagent/shorty-ruby.git
cd shorty-ruby && bundle
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
* Accesses to the short URL are tracked and a report is available by requesting
  the shortcode URL with a `+` appended to it

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

Fetching an access report for a shortcode:

```
curl -s \
  -H "Content-Type: application/json" \
  "http://localhost:9292/byDkfX+" | python -m json.tool

{
    "response": [
        {
            "referrer": "http://localhost:9292/",
            "time": "2019-09-20T21:06:24.375Z",
            "user_agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.13; rv:69.0) Gecko/20100101 Firefox/69.0"
        },
        {
            "referrer": "none",
            "time": "2019-09-20T21:03:19.013Z",
            "user_agent": "curl/7.54.0"
        },
        {
            "referrer": "none",
            "time": "2019-09-20T21:03:17.726Z",
            "user_agent": "curl/7.54.0"
        }
    ]
}
```


## Running Tests

Tests are located in `app_spec.rb` for all unit and integration tests.  Run
with:

```
bundle exec rspec
```
