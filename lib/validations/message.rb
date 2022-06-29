module Validations
  class Message
    CLASSIFY_SEPARATOR = '_'.freeze
    TITLEIZE_SEPARATOR = ' '.freeze

    # @errors [Hash | Array] output of dry-validation
    #         after validating params
    # @parent [Nil | String] key name of a field that has `errors`
    #         after validating params
    # Output: array of string that can be used to feed into
    # Errors::InvalidParamsError
    def build(errors, parent = nil)
      case errors
      when Hash
        errors.flat_map do |key, value|
          child = [parent, key].compact.join(' ')
          build(value, child)
        end
      when Array
        errors.flat_map do |error|
          "#{titleize(parent.to_s)} #{build(error)}"
        end
      else
        errors
      end
    end

    private

    def titleize(string)
      # NOTE: this is not a robust implementation of titleize
      string.split(CLASSIFY_SEPARATOR).map(&:capitalize).join(TITLEIZE_SEPARATOR)
    end
  end
end
