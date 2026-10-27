# A custom tool in a conversation where a customer is the user. A tool that requires email verification runs only
# for a customer who verified an email, and a verified email parameter always carries that email.
class Captain::Tools::PublicHttpTool < Captain::Tools::HttpTool
  EMAIL_REQUIRED = 'This tool needs a verified email, and this customer has not verified an email yet. ' \
                   'Verify their email with a one-time code first, then call this tool again. ' \
                   'If that is not possible, ask whether they want to talk to a support agent.'.freeze

  def perform(tool_context, **params)
    params = params_with_contact_phone(tool_context, params)
    return super(tool_context, **params) unless @custom_tool.requires_email_verification?

    verified_email = stored_verified_email(tool_context.state)
    return failure_result(EMAIL_REQUIRED, tool_context.state) unless verified_email

    # Set last, so a value from the model can never replace the verified email
    email_param = @custom_tool.verified_email_param
    super(tool_context, **(email_param ? params.merge(email_param.to_sym => verified_email) : params))
  end

  private

  # The model does not choose this value. A missing phone is left out rather than blocking the call.
  def params_with_contact_phone(tool_context, params)
    params = params.except(:phone, 'phone')
    phone = stored_contact_phone(tool_context.state)
    phone.present? ? params.merge(phone: phone) : params
  end
end
