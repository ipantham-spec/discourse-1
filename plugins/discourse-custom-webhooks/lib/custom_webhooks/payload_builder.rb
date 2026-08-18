# frozen_string_literal: true

module ::DiscourseCustomWebhooks
  # Builds the moderation event payload sent to the CSAM/ToSHUB moderation
  # pipeline. Carries the author's identity, the text, and any image links so the
  # pipeline can score the content. Pure data assembly (no network) so it can be
  # unit tested in isolation. Matches the "What Discourse Sends" contract.
  class PayloadBuilder
    def initialize(post, event:, event_id: nil)
      @post = post
      @event = event
      @event_id = event_id || SecureRandom.uuid
    end

    def build
      {
        event_id: @event_id,
        event: @event,
        event_type: event_type,
        post_id: @post.id,
        topic_id: @post.topic_id,
        post_number: @post.post_number,
        post_url: post_url,
        callback_url: callback_url,
        created_at: @post.created_at&.iso8601,
        updated_at: @post.updated_at&.iso8601,
        category_id: @post.topic&.category_id,
        actor: actor,
        recipients: recipients,
        text: {
          title: title,
          raw: @post.raw,
        },
        images: images,
        has_images: images.any?,
      }
    end

    private

    # topic (first post), reply, or pm — drives how the pipeline routes the event.
    def event_type
      return "pm" if @post.topic&.private_message?
      @post.is_first_post? ? "topic" : "reply"
    end

    def title
      @post.is_first_post? ? @post.topic&.title : nil
    end

    def actor
      user = @post.user
      {
        discourse_user_id: @post.user_id,
        username: user&.username,
        display_name: user&.name,
        sso_id: sso_id_for(@post.user_id),
        locale: user&.effective_locale,
        trust_level: user&.trust_level,
      }
    end

    # Present only for private messages; the report-abuse flow needs the
    # recipients' identities.
    def recipients
      return [] unless @post.topic&.private_message?

      @post
        .topic
        .allowed_users
        .reject { |u| u.id == @post.user_id }
        .map { |u| { discourse_user_id: u.id, username: u.username, sso_id: sso_id_for(u.id) } }
    end

    def images
      return [] unless SiteSetting.custom_webhooks_include_images

      @images ||=
        @post
          .uploads
          .to_a
          .select { |upload| image_upload?(upload) }
          .map do |upload|
            {
              url: url_for(upload),
              content_type: upload.respond_to?(:content_type) ? upload.content_type : nil,
              sha1: upload.sha1,
              short_url: upload.short_url,
              secure: !!upload.secure,
              filename: upload.original_filename,
            }
          end
    end

    def image_upload?(upload)
      return false if upload&.original_filename.blank?
      FileHelper.is_supported_image?(upload.original_filename)
    end

    # Prefer a presigned/CDN URL the moderation service can actually fetch. The S3
    # store exposes url_for (presigned for secure uploads); the local store does
    # not, so fall back to an absolute URL.
    def url_for(upload)
      store = Discourse.store
      if store.respond_to?(:url_for)
        store.url_for(upload)
      else
        UrlHelper.absolute(upload.url)
      end
    rescue StandardError
      UrlHelper.absolute(upload.url)
    end

    # Resolves the author's external identity from the associated account created
    # by the SSO provider (configurable so this plugin is not tied to a specific
    # authenticator). Nil when the user has no linked account.
    def sso_id_for(user_id)
      provider = SiteSetting.custom_webhooks_sso_provider
      return nil if provider.blank?
      UserAssociatedAccount.find_by(provider_name: provider, user_id: user_id)&.provider_uid
    end

    def post_url
      @post.full_url
    rescue StandardError
      "#{Discourse.base_url}/p/#{@post.id}"
    end

    # The plugin's own verdict-callback endpoint, so the moderation service takes
    # the callback destination from the plugin instead of hardcoding it.
    def callback_url
      "#{Discourse.base_url}/custom-webhooks/moderation/callback"
    end
  end
end
