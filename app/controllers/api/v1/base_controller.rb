module Api
  module V1
    class BaseController < ActionController::API

      protected

      def render_json_request(method, action, params, &block)
        params.delete :action
        params.delete :controller
        params.delete :format
        params[:advancedSyntax] = true if params[:advancedSyntax].nil?
        params[:analytics] = false if params[:analytics].nil?
        forwarded_ip = (request.env['HTTP_X_FORWARDED_FOR'] || request.remote_ip).split(',').first.strip
        forwarded_ip = nil if eval(ENV['RATE_LIMIT_WHITE_LIST']).include?(forwarded_ip)
        json = client.send(method, action, { params: params.to_param }, forwarded_ip)
        json = yield(json['objectID']) if block_given?
        render json: json, root: false
      rescue Algolia::AlgoliaProtocolError => e
        render text: e.message, status: e.code
      end

      private

      def client
        Thread.current[:algolia_client] ||= Client.new(ENV['ALGOLIASEARCH_APPLICATION_ID'], ENV['ALGOLIASEARCH_API_KEY'], ENV['ALGOLIASEARCH_API_KEY_RO'])
      end

    end

    class Client

      def initialize(application_id, api_key, forwarded_api_key)
        @client = HTTPClient.new
        @client.transparent_gzip_decompression = true
        @cluster = 2.upto(3).map { |i| "#{application_id}-#{i}" } # application_id-1 is dedicated to build
        @forwarded_api_key = forwarded_api_key
        @headers = {
          Algolia::Protocol::HEADER_API_KEY           => api_key,
          Algolia::Protocol::HEADER_APP_ID            => application_id,
          "Content-Type"                              => "application/json; charset=utf-8",
          "User-Agent"                                => "Algolia for Ruby (hnsearch)"
        }
      end

      def get(action, params, forwarded_ip)
        params = params.to_param if params
        request :GET, "#{action}#{'?' if !params.blank?}#{params}", forwarded_ip
      end

      def post(action, params, forwarded_ip)
        request :POST, action, forwarded_ip, params.to_json
      end

      def put(action, params, forwarded_ip)
        request :PUT, action, forwarded_ip, params.to_json
      end

      def delete(action, forwarded_ip)
        request :DELETE, action, forwarded_ip
      end

      private

      # Perform an HTTP request for the given uri and method
      # with common basic response handling. Will raise a
      # Algolia::AlgoliaProtocolError if the response has an error status code,
      # and will return the parsed JSON body on success, if there is one.
      def request(method, uri, forwarded_ip, data = nil)
        if forwarded_ip
          headers = @headers.merge({
            Algolia::Protocol::HEADER_FORWARDED_IP => forwarded_ip,
            Algolia::Protocol::HEADER_FORWARDED_API_KEY => @forwarded_api_key
          })
        else
          headers = @headers
        end

        @cluster.each do |c|
          begin
            url = "https://#{c}.algolia.io" + uri
            answer = case method
            when :GET
              @client.get(url, header: headers)
            when :POST
              @client.post(url, body: data, header: headers)
            when :PUT
              @client.put(url, body: data, header: headers)
            when :DELETE
              @client.delete(url, header: headers)
            end
            if answer.code >= 400 || answer.code < 200
              raise Algolia::AlgoliaProtocolError.new(answer.code, "#{method} #{url}: #{answer.content}")
            end
            return JSON.parse(answer.content)
          rescue Algolia::AlgoliaProtocolError => e
            if e.code != Algolia::Protocol::ERROR_TIMEOUT and e.code != Algolia::Protocol::ERROR_UNAVAILABLE
              raise
            end
          end
        end
        raise Algolia::AlgoliaProtocolError.new(500, "Cannot reach any hosts")
      end

    end
  end
end
