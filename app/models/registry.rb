module Registry
  include HTTParty
  base_uri 'http://proxy'

  def repositories
    get('/v2/_catalog', headers: headers_for_scope('registry:catalog:*'))['repositories']
  end

  def tags repository
    get("/v2/#{repository}/tags/list", headers: headers_for_scope("repository:#{repository}:pull"))['tags']
  end

  def delete_tag(repository, tag)
    digest = manifests(repository, tag)[0]
    delete_manifests repository, digest
  end

  def manifests(repository, reference)
    resp = get("/v2/#{repository}/manifests/#{reference}",
      headers: headers_for_scope("repository:#{repository}:pull", Accept: 'application/vnd.docker.distribution.manifest.v2+json'))
    [resp.headers['docker-content-digest'], resp]
  end

  def token(scope, user=nil)
    rsa_private_key = OpenSSL::PKey::RSA.new(File.read(File.join(Rails.root, 'config', 'private_key.pem')))

    payload = {
      iss: 'registry-token-issuer',
      sub: (user.nil? ? 'system-service' : user.username),
      aud: 'token-service',
      exp: 10.minutes.from_now.to_i,
      nbf: 1.minutes.ago.to_i,
      iat: Time.now.to_i,
      jti: SecureRandom.uuid,
      access: []
    }

    if scope
      scope_type, scope_name, scope_actions = scope.split(':')
      scope_actions = scope_actions.split(',')
      if user.nil?
        payload[:access] << {
          type: scope_type,
          name: scope_name,
          actions: scope_actions
        }
      else
        case scope_type
        when 'repository'
          namespace_name = scope_name.split('/').length == 2 ? scope_name.split('/').first : 'library'
          repository_name = scope_name.split('/').last
          namespace = Namespace.find_by(name: namespace_name)
          repository = namespace&.repositories.where(name: repository_name).first_or_initialize
          authorized_actions = []
          authorized_actions << 'pull' if user.can? :pull, repository
          authorized_actions += ['*', 'push'] if user.can? :push, repository
          authorized_actions.uniq!
          payload[:access] << {
            type: scope_type,
            name: scope_name,
            actions: authorized_actions
          }
        end
      end
    end

    header = {
      kid: Base32.encode(Digest::SHA256.digest(rsa_private_key.public_key.to_der)[0...30]).scan(/.{4}/).join(':')
    }

    JWT.encode payload, rsa_private_key, 'RS256', header
  end

  def delete_manifests(repository, reference)
    delete("/v2/#{repository}/manifests/#{reference}", headers: headers_for_scope("repository:#{repository}:*"))
  end

  def headers_for_scope(scope, other_headers = {})
    { 'Authorization': 'Bearer ' + token(scope) }.merge(other_headers)
  end

  module_function :repositories, :tags, :delete_tag, :delete_manifests, :token, :manifests, :headers_for_scope
end
