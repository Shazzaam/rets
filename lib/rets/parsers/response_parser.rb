require_relative '../transaction'
require_relative 'compact'
require 'rexml/document'

module RETS
  class ResponseParser
    def parse_key_value(xml)
      parse_common(xml) do |doc|
        parsed = nil
        first_child = doc.get_elements('/RETS/RETS-RESPONSE')[0] ? doc.get_elements('/RETS/RETS-RESPONSE')[0] : doc.get_elements('/RETS')[0]
        unless first_child.nil?
          parsed = {}
          first_child.text.each_line do |line|
            (key, value) = line.strip.split('=')
            key.strip! if key
            value.strip! if value
            parsed[key] = value
          end
        else
          raise 'Response was not a proper RETS XML doc!'
        end
        
        if parsed.nil?
          raise "Response was not valid key/value format"
        else
          parsed
        end
      end
    end

    def parse_results(xml, format)
      parse_common(xml) do |doc|
        parser = get_parser_by_name(format)
        parser.parse_results(doc)
      end
    end

    def parse_count(xml)
      parse_common(xml) do |doc|
        doc.get_elements('/RETS/COUNT')[0].attributes['Records']
      end
    end

    def parse_metadata(xml, format, type)
      parse_common(xml) do |doc|
        #return REXML::Document.new(xml)
        parser = get_parser_by_name(format)
        parser.parse_results(doc, type)
      end
    end

    def parse_object_response(xml)
      parse_common(xml) do |doc|
        # XXX
      end
    end

    private

    def parse_common(xml, &block)
      if xml == ''
        raise RETSException, 'No transaction body was returned!'
      end

      doc = REXML::Document.new(xml)
      
      root = doc.root
      if root.nil? || root.name != 'RETS'
        raise "Response had invalid root node. Document was: #{doc.inspect}"
      end

      transaction = Transaction.new
      transaction.reply_code = root.attributes['ReplyCode']
      transaction.reply_text = root.attributes['ReplyText']
      transaction.maxrows    = (doc.get_elements('/RETS/MAXROWS').length > 0)


      # XXX: If it turns out we need to parse the response of errors, then this will
      # need to change.
      begin
        if transaction.reply_code.to_i > 0 && transaction.reply_code.to_i != 20201
          exception_type = Client::EXCEPTION_TYPES[transaction.reply_code.to_i] || RETSTransactionException
          #raise exception_type, "#{transaction.reply_code} - #{transaction.reply_text}"
        end
      rescue Exception => e
        puts e.message
        puts "#{transaction.reply_code} - #{transaction.reply_text}"
      end

      transaction.response = yield doc
      return transaction
    end

    def get_parser_by_name(name)
      case name
        when 'COMPACT', 'COMPACT-DECODED'
          type = RETS::CompactDataParser
        else
          raise "Invalid format #{name}"
      end
      type.new
    end
  end
end

