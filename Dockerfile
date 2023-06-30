FROM ruby:alpine

COPY . /app
WORKDIR /app
RUN apk add --no-cache ruby-dev build-base curl libc6-compat
RUN gem install -N rack rackup typhoeus nokogiri webrick
CMD ["rackup", "-o", "0.0.0.0"]

