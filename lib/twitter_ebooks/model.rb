#!/usr/bin/env ruby
# encoding: utf-8

require 'json'
require 'set'
require 'digest/md5'
require 'csv'

module Ebooks
  class Model
    attr_accessor :hash, :tokens, :sentences, :mentions, :keywords

    def self.consume(txtpath)
      Model.new.consume(txtpath)
    end

    def self.load(path)
      model = Model.new
      model.instance_eval do
        props = Marshal.load(File.open(path, 'rb') { |f| f.read })
        @tokens = props[:tokens]
        @sentences = props[:sentences]
        @mentions = props[:mentions]
        @keywords = props[:keywords]
      end
      model
    end

    def save(path)
      File.open(path, 'wb') do |f|
        f.write(Marshal.dump({
          tokens: @tokens,
          sentences: @sentences,
          mentions: @mentions,
          keywords: @keywords
        }))
      end
      self
    end

    def initialize
      # This is the only source of actual strings in the model. It is
      # an array of unique tokens. Manipulation of a token is mostly done
      # using its index in this array, which we call a "tiki"
      @tokens = []

      # Reverse lookup tiki by token, for faster generation
      @tikis = {}
    end

    def tikify(token)
      @tikis[token] or (@tokens << token and @tikis[token] = @tokens.length-1)
    end

    def mass_tikify(text)
      sentences = NLP.sentences(text)

      sentences.map do |s|
        tokens = NLP.tokenize(s).reject do |t|
          # Don't include usernames/urls as tokens
          t.include?('@') || t.include?('http')
        end

        tokens.map { |t| tikify(t) }
      end
    end

    def consume(path)
      content = File.read(path, :encoding => 'utf-8')
      @hash = Digest::MD5.hexdigest(content)

      if path.split('.')[-1] == "json"
        log "Reading json corpus from #{path}"
        lines = JSON.parse(content).map do |tweet|
          tweet['text']
        end
      elsif path.split('.')[-1] == "csv"
        log "Reading CSV corpus from #{path}"
        content = CSV.parse(content)
        header = content.shift
        text_col = header.index('text')
        lines = content.map do |tweet|
          tweet[text_col]
        end
      else
        log "Reading plaintext corpus from #{path}"
        lines = content.split("\n")
      end

      log "Removing commented lines and sorting mentions"

      statements = []
      mentions = []
      lines.each do |l|
        next if l.start_with?('#') # Remove commented lines
        next if l.include?('RT') || l.include?('MT') # Remove soft retweets

        if l.include?('@')
          mentions << NLP.normalize(l)
        else
          statements << NLP.normalize(l)
        end
      end

      text = statements.join("\n")
      mention_text = mentions.join("\n")

      lines = nil; statements = nil; mentions = nil # Allow garbage collection

      log "Tokenizing #{text.count('\n')} statements and #{mention_text.count('\n')} mentions"

      @sentences = mass_tikify(text)
      @mentions = mass_tikify(mention_text)

      log "Ranking keywords"
      @keywords = NLP.keywords(text).top(200).map(&:to_s)

      self
    end

    def fix(tweet)
      # This seems to require an external api call
      #begin
      #  fixer = NLP.gingerice.parse(tweet)
      #  log fixer if fixer['corrections']
      #  tweet = fixer['result']
      #rescue Exception => e
      #  log e.message
      #  log e.backtrace
      #end

      NLP.htmlentities.decode tweet
    end

    def valid_tweet?(tikis, limit)
      tweet = NLP.reconstruct(tikis, @tokens)
      tweet.length <= limit && !NLP.unmatched_enclosers?(tweet)
    end

    def make_statement(limit=140, generator=nil, retry_limit=10)
      responding = !generator.nil?
      generator ||= SuffixGenerator.build(@sentences)

      retries = 0
      tweet = ""

      while (tikis = generator.generate(3, :bigrams)) do
        next if tikis.length <= 3 && !responding
        break if valid_tweet?(tikis, limit)

        retries += 1
        break if retries >= retry_limit
      end

      if verbatim?(tikis) && tikis.length > 3 # We made a verbatim tweet by accident
        while (tikis = generator.generate(3, :unigrams)) do
          break if valid_tweet?(tikis, limit) && !verbatim?(tikis)

          retries += 1
          break if retries >= retry_limit
        end
      end

      tweet = NLP.reconstruct(tikis, @tokens)

      if retries >= retry_limit
        log "Unable to produce valid non-verbatim tweet; using \"#{tweet}\""
      end

      fix tweet
    end

    # Test if a sentence has been copied verbatim from original
    def verbatim?(tokens)
      @sentences.include?(tokens) || @mentions.include?(tokens)
    end

    # Finds all relevant tokenized sentences to given input by
    # comparing non-stopword token overlaps
    def find_relevant(sentences, input)
      relevant = []
      slightly_relevant = []

      tokenized = NLP.tokenize(input).map(&:downcase)

      sentences.each do |sent|
        tokenized.each do |token|
          if sent.map { |tiki| @tokens[tiki].downcase }.include?(token)
            relevant << sent unless NLP.stopword?(token)
            slightly_relevant << sent
          end
        end
      end

      [relevant, slightly_relevant]
    end

    # Generates a response by looking for related sentences
    # in the corpus and building a smaller generator from these
    def make_response(input, limit=140, sentences=@mentions)
      # Prefer mentions
      relevant, slightly_relevant = find_relevant(sentences, input)

      if relevant.length >= 3
        generator = SuffixGenerator.build(relevant)
        make_statement(limit, generator)
      elsif slightly_relevant.length >= 5
        generator = SuffixGenerator.build(slightly_relevant)
        make_statement(limit, generator)
      elsif sentences.equal?(@mentions)
        make_response(input, limit, @sentences)
      else
        make_statement(limit)
      end
    end
  end
end
