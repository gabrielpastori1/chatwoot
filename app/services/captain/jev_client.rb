class Captain::JevClient
  include Integrations::LlmInstrumentationConstants

  # TypeSafe-compatible surface on Vercel AI Gateway. The request body stays
  # { model, state, questions } and answers still use noul/choice/score.
  ENDPOINT = 'https://ai-gateway.vercel.sh/typesafe'.freeze
  SYSTEM_ONE_PATH = '/v1/systemone'.freeze
  OPENROUTER_BASES = ['https://openrouter.ai', 'https://openrouter.ai/api'].freeze

  class HTTPError < StandardError
    attr_reader :status, :retry_after

    def initialize(response)
      @status = response.status
      @retry_after = response.headers['retry-after']&.to_i
      super("Jev request failed with status #{status}: #{response.body}")
    end
  end

  def initialize(account_id:, feature:, conversation_id: nil)
    @account_id = account_id
    @conversation_id = conversation_id
    @feature = feature
  end

  def self.request_body(model:, state:, questions:)
    { model: model, state: state, questions: questions }.to_json
  end

  def self.api_key
    GlobalConfigService.load('CAPTAIN_OPENROUTER_API_KEY', nil)
  end

  def self.endpoint
    "#{decision_base}#{SYSTEM_ONE_PATH}"
  end

  def self.decision_base
    configured = GlobalConfigService.load('CAPTAIN_OPENROUTER_DECISION_MODEL_ENDPOINT', nil).to_s.strip.chomp('/')
    return ENDPOINT if configured.blank? || OPENROUTER_BASES.include?(configured)

    configured
  end

  def call(body:)
    trace_jev_call(body) do
      response = connection.post(self.class.endpoint, body)
      raise HTTPError, response unless response.success?

      data = JSON.parse(response.body)
      yield(data) if block_given?
      data
    end
  end

  private

  def trace_jev_call(body, &)
    return yield unless ChatwootApp.otel_enabled?

    traced_jev_call(body, &)
  end

  # Tracing is best-effort: a tracing failure must not block the Jev call or discard a response that already used provider credit.
  def traced_jev_call(body, &)
    outcome = {}
    OpentelemetryConfig.tracer.in_span("llm.jev.#{@feature}", kind: :client) do |span|
      request_model = JSON.parse(body).fetch('model')
      set_request_attributes(span, body)
      call_in_span(span, outcome, &)
      set_response_attributes(span, outcome[:result], request_model)
    end
    outcome[:result]
  rescue StandardError => e
    raise outcome[:error] if outcome.key?(:error)

    ChatwootExceptionTracker.new(e).capture_exception
    outcome.key?(:result) ? outcome[:result] : yield
  end

  def call_in_span(span, outcome)
    outcome[:result] = yield
  rescue StandardError => e
    outcome[:error] = e
    span.status = OpenTelemetry::Trace::Status.error(e.message)
    raise
  end

  def set_request_attributes(span, body)
    span.set_attribute(ATTR_LANGFUSE_OBSERVATION_TYPE, 'generation')
    span.set_attribute(ATTR_LANGFUSE_OBSERVATION_INPUT, body)
    span.set_attribute(ATTR_LANGFUSE_USER_ID, @account_id.to_s)
    span.set_attribute(ATTR_LANGFUSE_TAGS, [@feature].to_json)
    span.set_attribute(ATTR_LANGFUSE_SESSION_ID, "#{@account_id}_#{@conversation_id}") if @conversation_id
  end

  def set_response_attributes(span, result, request_model)
    usage = result['usage'] || {}
    span.set_attribute(ATTR_LANGFUSE_OBSERVATION_OUTPUT, result.to_json)
    span.set_attribute(ATTR_LANGFUSE_OBSERVATION_MODEL_NAME, result['model'] || request_model)
    span.set_attribute(ATTR_GEN_AI_USAGE_INPUT_TOKENS, usage['input_tokens']) if usage['input_tokens']
    span.set_attribute(ATTR_GEN_AI_USAGE_OUTPUT_TOKENS, usage['output_tokens']) if usage['output_tokens']
    span.set_attribute(ATTR_LANGFUSE_OBSERVATION_COST_DETAILS, { total: usage['cost'] }.to_json) if usage['cost'].is_a?(Numeric)
  end

  def connection
    Faraday.new do |client|
      client.options.open_timeout = 3
      client.options.timeout = 15
      client.headers['Authorization'] = "Bearer #{self.class.api_key}"
      client.headers['Content-Type'] = 'application/json'
    end
  end
end

Captain::JevClient.prepend_mod_with('Captain::JevClient')
