# A custom tool where an admin or an agent is the user: the playground and reply suggestions.
# The model fills verified parameters with the value it was given, and the result says when that value is not one the customer verified.
class Captain::Tools::CopilotHttpTool < Captain::Tools::HttpTool
  UNVERIFIED_VALUE_NOTE = 'The email passed to this tool was not verified by the customer.'.freeze
  UNVERIFIED_PHONE_NOTE = 'The phone passed to this tool is not the customer phone.'.freeze
  PHONE_PARAMETER_DESCRIPTION = 'The customer phone number. Use the phone number already known for this customer.'.freeze

  def self.model_fills_verified_values?
    true
  end

  def self.extra_parameters
    [{ name: :phone, type: 'string', description: PHONE_PARAMETER_DESCRIPTION, required: false }]
  end

  def perform(tool_context, **params)
    result = append_email_note(super, tool_context, params)
    append_phone_note(result, tool_context, params)
  end

  private

  def append_email_note(result, tool_context, params)
    email_param = @custom_tool.verified_email_param
    return result unless email_param

    verified_email = stored_verified_email(tool_context.state)
    return result if verified_email && params[email_param.to_sym].to_s.strip.casecmp?(verified_email)

    "#{result}\n\n#{UNVERIFIED_VALUE_NOTE}"
  end

  def append_phone_note(result, tool_context, params)
    contact_phone = stored_contact_phone(tool_context.state)
    return result if contact_phone.blank? || same_phone?(params[:phone], contact_phone)

    "#{result}\n\n#{UNVERIFIED_PHONE_NOTE}"
  end
end
