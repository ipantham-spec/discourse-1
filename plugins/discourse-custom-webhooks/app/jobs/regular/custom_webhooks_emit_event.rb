# frozen_string_literal: true

module Jobs
  # Builds and sends the custom webhook for a post-based event out-of-band, so
  # the triggering action (post create/edit) is never delayed by the delivery.
  class CustomWebhooksEmitEvent < ::Jobs::Base
    def execute(args)
      return unless DiscourseCustomWebhooks::Emitter.enabled?

      event = args[:event].to_s
      return unless DiscourseCustomWebhooks::Emitter.subscribed?(event)

      post = Post.find_by(id: args[:post_id])
      return if post.blank?

      payload = DiscourseCustomWebhooks::PayloadBuilder.new(post, event: event).build
      DiscourseCustomWebhooks::Emitter.deliver(payload, ref: "post #{post.id} (#{event})")
    end
  end
end
