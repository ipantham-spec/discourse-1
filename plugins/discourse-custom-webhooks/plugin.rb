# frozen_string_literal: true

# name: discourse-custom-webhooks
# about: Sends signed moderation events (HMAC-SHA256, with optional mutual TLS) to an external content-moderation pipeline (e.g. CSAM/ToSHUB) when selected forum events happen. All transport settings are configured from the admin UI.
# version: 0.1
# authors: Discourse
# url: https://github.com/discourse/discourse/tree/main/plugins/discourse-custom-webhooks

enabled_site_setting :custom_webhooks_enabled

if File.exist?(File.expand_path("assets/stylesheets/common/custom-webhooks.scss", __dir__))
  register_asset "stylesheets/common/custom-webhooks.scss"
end

module ::DiscourseCustomWebhooks
  PLUGIN_NAME = "discourse-custom-webhooks"
end

# Groups every transport input onto one filtered admin settings page.
register_site_setting_area("custom_webhooks")

require_relative "lib/custom_webhooks/signature"
require_relative "lib/custom_webhooks/payload_builder"
require_relative "lib/custom_webhooks/emitter"

# Admin config page (Admin → Plugins → Custom webhooks). use_new_show_route
# renders the modern plugin show page with top tabs; the generated Settings tab
# exposes every transport input below.
add_admin_route("custom_webhooks.admin.title", "custom-webhooks", { use_new_show_route: true })

# Inbound moderation loop: the pipeline posts a signed verdict to the callback,
# and the composer nudge posts to the synchronous text check.
Discourse::Application.routes.append do
  post "/custom-webhooks/moderation/callback" => "custom_webhooks_moderation#callback"
  post "/custom-webhooks/moderation/check" => "custom_webhooks_moderation#check"
end

after_initialize do
  require_relative "app/jobs/regular/custom_webhooks_emit_event"
  require_relative "app/models/reviewable_custom_webhooks_moderation"
  require_relative "app/serializers/reviewable_custom_webhooks_moderation_serializer"
  require_relative "app/controllers/custom_webhooks_moderation_controller"

  register_reviewable_type ReviewableCustomWebhooksModeration

  # Enqueues a moderation event for a post-based event when it is one of the
  # The async event path is for IMAGES only (hold-pending → CTD/CSAM). Text is
  # gated inline pre-publish by the composer nudge (Khoros nudging parity), so a
  # text-only post produces no async event. Delivery is out-of-band so posting is
  # never blocked by the round trip.
  emit_for_post =
    lambda do |post, event|
      return unless DiscourseCustomWebhooks::Emitter.enabled?
      return unless DiscourseCustomWebhooks::Emitter.eligible?(post)
      return unless DiscourseCustomWebhooks::Emitter.subscribed?(event)
      return unless SiteSetting.custom_webhooks_include_images
      return unless DiscourseCustomWebhooks::Emitter.post_has_image?(post)

      if SiteSetting.custom_webhooks_hold_images_pending && !post.hidden?
        post.hide!(PostActionType.types[:inappropriate])
      end

      Jobs.enqueue(:custom_webhooks_emit_event, post_id: post.id, event: event)
    end

  on(:post_created) do |post, _opts, _user|
    # A new topic's first post also fires :post_created. When "topic_created" is
    # subscribed too, the :topic_created hook below already emits it — skip here
    # so the same post isn't sent twice (with two different event_ids, which
    # would defeat the forums-side event_id dedup).
    next if post.is_first_post? && DiscourseCustomWebhooks::Emitter.subscribed?("topic_created")
    emit_for_post.call(post, "post_created")
  end
  on(:post_edited) { |post, _topic_changed, _opts| emit_for_post.call(post, "post_edited") }
  on(:topic_created) do |topic, _opts, _user|
    next unless DiscourseCustomWebhooks::Emitter.subscribed?("topic_created")
    emit_for_post.call(topic.first_post, "topic_created")
  end
end
