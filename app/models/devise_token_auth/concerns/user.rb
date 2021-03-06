require 'bcrypt'

module DeviseTokenAuth::Concerns::User
  extend ActiveSupport::Concern

  def self.tokens_match?(token_hash, token)
    @token_equality_cache ||= {}

    key = "#{token_hash}/#{token}"
    result = @token_equality_cache[key] ||= (::BCrypt::Password.new(token_hash) == token)
    if @token_equality_cache.size > 10000
      @token_equality_cache = {}
    end
    result
  end

  included do

    class_variable_set(:@@finder_methods, {})

    # Hack to check if devise is already enabled
    unless self.method_defined?(:devise_modules)
      devise :database_authenticatable, :registerable,
          :recoverable, :trackable, :validatable, :confirmable
    else
      self.devise_modules.delete(:omniauthable)
    end

    unless tokens_has_json_column_type?
      serialize :tokens, JSON
    end

    if DeviseTokenAuth.default_callbacks
      include DeviseTokenAuth::Concerns::UserOmniauthCallbacks
    end

    # can't set default on text fields in mysql, simulate here instead.
    after_save :set_empty_token_hash
    after_initialize :set_empty_token_hash

    # get rid of dead tokens
    before_save :destroy_expired_tokens

    # remove old tokens if password has changed
    before_save :remove_tokens_after_password_reset

    # don't use default devise email validation
    def email_required?
      false
    end

    def email_changed?
      false
    end

    def will_save_change_to_email?
      false
    end

    def password_required?
      return false unless provider == 'email'
      super
    end

    def provider
      if has_attribute?(:provider)
        read_attribute(:provider)
      else
        self.class.authentication_keys.first.to_s
      end
    end

    # override devise method to include additional info as opts hash
    def send_confirmation_instructions(opts = {})
      generate_confirmation_token! unless @raw_confirmation_token

      opts[:client_config] ||= "default"
      opts[:to] = unconfirmed_email if pending_reconfirmation?
      opts[:redirect_url] ||= DeviseTokenAuth.default_confirm_success_url

      send_devise_notification(:confirmation_instructions, @raw_confirmation_token, opts)
    end

    # override devise method to include additional info as opts hash
    def send_reset_password_instructions(opts = {})
      set_reset_password_token.tap do |token|
        opts[:client_config] ||= "default"
        send_devise_notification(:reset_password_instructions, token, opts)
      end
    end

    # override devise method to include additional info as opts hash
    def send_unlock_instructions(opts = {})
      raw, enc = Devise.token_generator.generate(self.class, :unlock_token)
      self.unlock_token = enc
      save(validate: false)

      opts[:client_config] ||= "default"
      send_devise_notification(:unlock_instructions, raw, opts)

      raw
    end

    def create_token(client_id: nil, token: nil, expiry: nil)
      client_id ||= SecureRandom.urlsafe_base64(nil, false)
      token ||= SecureRandom.urlsafe_base64(nil, false)
      expiry ||= (Time.now + token_lifespan).to_i

      tokens[client_id] = {
        token: BCrypt::Password.create(token),
        expiry: expiry
      }
      [client_id, token, expiry]
    end
  end

  module ClassMethods

    # This attempts 4 different finds to try and get the resource, depending on
    # how the resources have been configured and accounting for backwards
    # compatibility prior to multiple authentication methods.
    #
    def find_resource(id, provider)
      # 1. If a finder method has been registered for this provider, use it!
      #
      finder_method = finder_methods[provider.try(:to_sym)]
      return finder_method.call(id) if finder_method

      # 2. This check is for backwards compatibility. On introducing multiple
      #    oauth methods, the uid header changed to include the provider. Prior
      #    to this change, however, the uid was only the identifier.
      #    Consequently, if we don't have the provider we fall back to the old
      #    behaviour of searching by uid. If we don't have a uid (i.e. we're
      #    allowing multiple auth methods) then we default to something sane.
      #
      if provider.nil?
        field = column_names.include?("uid") ? "uid" : authentication_keys.first
        return case_sensitive_find("#{field} = ?", id)
      end

      id.downcase! if self.case_insensitive_keys.include?(provider.to_sym)

      # 3. We then search using {provider: provider, uid: uid} to cover the
      #    default behaviour which doesn't allow multiple authentication
      #    methods for a single resource
      #
      if column_names.include?("uid") && column_names.include?("provider")
        resource = case_sensitive_find("uid = ? AND provider = ?", id, provider)
        return resource if resource
      end

      # 4. If we're at this point, we've either:
      #
      #  A. Got someone who hasn't registered yet
      #  B. Are using a non-email field to identify users
      #
      # If A is the case, we likely won't have a column which corresponds to
      # the value of "provider" (e.g. "twitter"). Consequently, bail out to
      # avoid running a query selecting on a column we don't have.
      #
      return nil unless column_names.include?(provider.to_s)

      case_sensitive_find("#{provider} = ?", id)
    end

    def case_sensitive_find(query, *args)
      if ActiveRecord::Base.connection.adapter_name.downcase.starts_with? 'mysql'
        query = "BINARY " + query
      end

      where(query, *args).first
    end

    def authentication_field_for(allowed_fields)
      (allowed_fields & authentication_keys).first
    end

    # These two methods must use .class_variable_get or the class variable gets
    # set on this ClassMethods module, instead of the class including it
    def resource_finder_for(resource, callable)
      self.class_variable_get(:@@finder_methods)[resource.to_sym] = callable
    end

    def finder_methods
      self.class_variable_get(:@@finder_methods)
    end

    protected

    def tokens_has_json_column_type?
      database_exists? && table_exists? && self.columns_hash['tokens'] && self.columns_hash['tokens'].type.in?([:json, :jsonb])
    end

    def database_exists?
      ActiveRecord::Base.connection_pool.with_connection { |con| con.active? } rescue false
    end
  end


  def valid_token?(token, client_id='default')

    return false unless tokens[client_id].present?

    return true if token_is_current?(token, client_id)
    return true if token_can_be_reused?(token, client_id)

    # return false if none of the above conditions are met
    return false
  end


  # this must be done from the controller so that additional params
  # can be passed on from the client
  def send_confirmation_notification?
    false
  end


  def token_is_current?(token, client_id)
    # ghetto HashWithIndifferentAccess
    expiry     = self.tokens[client_id]['expiry'] || self.tokens[client_id][:expiry]
    token_hash = self.tokens[client_id]['token'] || self.tokens[client_id][:token]

    return true if (
      # ensure that expiry and token are set
      expiry && token &&

      # ensure that the token has not yet expired
      DateTime.strptime(expiry.to_s, '%s') > Time.now &&

      # ensure that the token is valid
      DeviseTokenAuth::Concerns::User.tokens_match?(token_hash, token)
    )
  end


  # allow batch requests to use the previous token
  def token_can_be_reused?(token, client_id)
    # ghetto HashWithIndifferentAccess
    updated_at = self.tokens[client_id]['updated_at'] || self.tokens[client_id][:updated_at]
    last_token = self.tokens[client_id]['last_token'] || self.tokens[client_id][:last_token]


    return true if (
      # ensure that the last token and its creation time exist
      updated_at && last_token &&

      # ensure that previous token falls within the batch buffer throttle time of the last request
      Time.parse(updated_at) > Time.now - DeviseTokenAuth.batch_request_buffer_throttle &&

      # ensure that the token is valid
      ::BCrypt::Password.new(last_token) == token
    )
  end


  # update user's auth token (should happen on each request)
  def create_new_auth_token(client_id=nil, provider_id=nil, provider=nil)
    client_id  ||= SecureRandom.urlsafe_base64(nil, false)
    token        = SecureRandom.urlsafe_base64(nil, false)
    token_hash   = ::BCrypt::Password.create(token)
    expiry       = (Time.now + token_lifespan).to_i

    last_token = tokens.fetch(client_id, {}).with_indifferent_access[:token]

    self.tokens[client_id] = {
      token:      token_hash,
      expiry:     expiry,
      last_token: last_token,
      updated_at: Time.now
    }

    return update_auth_header(token, client_id, provider_id, provider)
  end

  def build_auth_header(token, client_id='default', provider_id, provider)
    # If we've not been given a specific provider, intuit it. This may occur
    # when logging in through standard devise (for example). See the check
    # for DeviseTokenAuth.enable_standard_devise_support in:
    #
    #  DeviseAuthToken::SetUserToken#set_user_token
    #
    provider ||= self.class.authentication_keys.first.to_s
    provider_id ||= send(provider)

    # client may use expiry to prevent validation request if expired
    # must be cast as string or headers will break
    expiry = tokens.fetch(client_id, {}).with_indifferent_access[:expiry].to_s

    return {
      DeviseTokenAuth.headers_names[:"access-token"] => token,
      DeviseTokenAuth.headers_names[:"token-type"]   => "Bearer",
      DeviseTokenAuth.headers_names[:"client"]       => client_id,
      DeviseTokenAuth.headers_names[:"expiry"]       => expiry,
      DeviseTokenAuth.headers_names[:"provider"]     => provider,
      DeviseTokenAuth.headers_names[:"uid"]          => provider_id
    }
  end

  def update_auth_header(token, client_id='default', provider_id, provider)
    build_auth_header(token, client_id, provider_id, provider).tap do |headers|
      # expiry = headers[DeviseTokenAuth.headers_names[:"expiry"]]

      while tokens.any? && DeviseTokenAuth.max_number_of_devices < tokens.length
        # Using Enumerable#min_by on a Hash will typecast it into an associative
        #   Array (i.e. an Array of key-value Array pairs).
        oldest_cid, _ = tokens.min_by { |_cid, v| v[:expiry] || v["expiry"] }

        # Delete the token data for the oldest client
        tokens.delete(oldest_cid)
      end

      # Save the updated tokens Hash
      save!
    end
  end

  def build_auth_url(base_url, args)
    args[:uid]      = try(:uid) || try(:email)
    args[:provider] = try(:provider)
    args[:expiry]   = tokens[args[:client_id]]['expiry']

    DeviseTokenAuth::Url.generate(base_url, args)
  end


  def extend_batch_buffer(token, client_id, provider_id, provider)
    self.tokens[client_id]['updated_at'] = Time.now

    return update_auth_header(token, client_id, provider_id, provider)\
  end

  def confirmed?
    devise_modules.exclude?(:confirmable) || super
  end

  def token_validation_response
    as_json(except: [:tokens, :created_at, :updated_at])
  end

  def token_lifespan
    DeviseTokenAuth.token_lifespan
  end

  protected

  # only validate unique email among users that registered by email
  def unique_email_user
    return true unless self.class.column_names.include?('provider')

    if self.class.where(provider: 'email', email: email).count > 0
      errors.add(:email, :already_in_use)
    end
  end

  def set_empty_token_hash
    self.tokens ||= {} if has_attribute?(:tokens)
  end

  def sync_uid
    if provider == 'email' && has_attribute?(:uid)
      self.uid = email
    end
  end

  def destroy_expired_tokens
    if tokens.present? && tokens.any?
      tokens.delete_if do |_cid, v|
        expiry = v[:expiry] || v["expiry"]
        DateTime.strptime(expiry.to_s, '%s') < Time.now
      end
    end
  end

  def remove_tokens_after_password_reset
    # Only remove older tokens if necessary
    return unless DeviseTokenAuth.remove_tokens_after_password_reset &&
                  encrypted_password_changed? && tokens.present? && tokens.many?

    # Keep only the newest client_id/token, which was set after the password
    #   was reset.
    #
    # Using Enumerable#max_by on a Hash will typecast it into an associative
    #   Array and return a single key-value Array pair, so convert it back into
    #   a Hash.
    client_id, token_data = tokens.max_by do |_cid, v|
      Time.zone.parse(v[:updated_at] || v['updated_at'])
    end

    self.tokens = {client_id => token_data}
  end

end
