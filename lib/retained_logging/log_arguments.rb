require "active_support/core_ext/object/deep_dup"
require "time"
require "date"

module RetainedLogging
  module LogArguments
    CATEGORIES = %w[errors warnings request_failures deployment_signals runtime_signals].freeze
    PROPERTIES = {
      component: { type: "string", enum: %w[web job all], default: "all" },
      category: { type: "string", enum: CATEGORIES + [ "all" ], default: "all" },
      lookback_minutes: { type: "integer", minimum: 1, maximum: 1440, default: 15 },
      limit: { type: "integer", minimum: 1, maximum: 100, default: 25 },
      window_end: { type: "string", pattern: '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z\z',
        description: "UTC window end within retained history; defaults to now. Windows include start and exclude end." },
      continuation: { type: "string", minLength: 1, maxLength: 4096,
        description: "Signed continuation from the previous page. Repeat every original selector unchanged." }
    }.freeze

    def self.schema
      # JSON Schema uses ECMA anchors, unlike Ruby's absolute string anchors.
      properties = PROPERTIES.deep_dup
      properties[:window_end][:pattern] = properties[:window_end][:pattern].sub('\A', "^").sub('\z', "$")
      { type: "object", properties: properties, required: [], additionalProperties: false }
    end

    def self.valid?(arguments)
      return false unless arguments.is_a?(Hash) && (arguments.keys - PROPERTIES.keys.map(&:to_s)).empty?
      PROPERTIES.all? do |name, rule|
        next true unless arguments.key?(name.to_s)
        value = arguments[name.to_s]
        if rule[:type] == "integer"
          value.is_a?(Integer) && value.between?(rule[:minimum], rule[:maximum])
        else
          value.is_a?(String) && value.valid_encoding? &&
            (!rule[:enum] || rule[:enum].include?(value)) &&
            (!rule[:maxLength] || value.bytesize.between?(rule[:minLength], rule[:maxLength])) &&
            (!rule[:pattern] || (value.match?(Regexp.new(rule[:pattern])) && utc_time(value)))
        end
      end
    end

    def self.utc_time(value)
      return unless value.is_a?(String) && value.match?(Regexp.new(PROPERTIES[:window_end][:pattern]))
      Date.iso8601(value[0, 10])
      time = Time.iso8601(value)
      time if time.strftime("%Y-%m-%dT%H:%M:%S") == value[0, 19]
    rescue ArgumentError
      nil
    end
  end
end
