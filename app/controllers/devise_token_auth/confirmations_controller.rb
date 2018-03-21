module DeviseTokenAuth
  class ConfirmationsController < DeviseTokenAuth::ApplicationController
    def show
      @resource = resource_class.confirm_by_token(params[:confirmation_token])

      if @resource && @resource.id
        client_id, token = @resource.create_token expiry: expiry

        sign_in(@resource)
        @resource.save!

        yield @resource if block_given?

        redirect_to @resource.build_auth_url(confirm_success_url, redirect_headers(client_id, token))
      else
        raise ActionController::RoutingError.new('Not Found')
      end
    end

    protected

    # TODO: move this to the DeviseTokenAuth::Concerns::User?
    # This is entirely dependent on the internals of the @resource, not the request...
    def expiry
      if @resource.has_attribute?(:sign_in_count) && @resource.sign_in_count > 0
        (Time.now + 1.second).to_i
      end
    end

    def confirm_success_url
      params[:redirect_url] || DeviseTokenAuth.default_confirm_success_url
    end

    def redirect_headers(client_id, token)
      build_redirect_headers token, client_id, {account_confirmation_success: true}
    end
  end
end
