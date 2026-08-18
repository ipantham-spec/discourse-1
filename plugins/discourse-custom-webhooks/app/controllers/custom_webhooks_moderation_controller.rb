# frozen_string_literal: true

# Receives moderation verdicts from the moderation pipeline and applies the
# result to the post: clean -> publish (unhide); text violation -> keep the post
# visible and raise a review-queue item (Khoros "post anyway" parity — a
# moderator decides whether to hide it); CSAM in a public post -> destroy; CSAM
# in a PM -> keep hidden + review. Also serves the synchronous pre-publish text
# check and the nudge-metrics recorder used by the composer nudge. Every action
# is written to the staff action log.
class CustomWebhooksModerationController < ::ApplicationController
  requires_plugin "discourse-custom-webhooks"

  skip_before_action :verify_authenticity_token, only: [:callback]
  skip_before_action :redirect_to_login_if_required, only: [:callback]
  skip_before_action :check_xhr, only: [:callback]
  before_action :ensure_enabled
  before_action :verify_signature, only: [:callback]
  before_action :ensure_logged_in, only: %i[check nudge_metric]

  SIGNATURE_HEADER = "HTTP_X_FORUMS_SIGNATURE"
  PROCESSED_TTL = 7.days
  NUDGE_ACTIONS = %w[edit post_anyway].freeze

  # Synchronous pre-publish text check used by the composer nudge. Returns the
  # pipeline's text verdict so the composer can warn before the post goes live.
  # Fails open (can_publish: true) so moderation never hard-blocks composing.
  def check
    return render json: { can_publish: true } unless SiteSetting.custom_webhooks_check_text

    url = SiteSetting.custom_webhooks_text_check_url
    return render json: { can_publish: true } if url.blank?

    event_id = SecureRandom.uuid
    body = {
      event_id: event_id,
      actor: {
        sso_id: sso_id_for(current_user&.id),
        locale: current_user&.effective_locale,
        trust_level: current_user&.trust_level,
      },
      text: {
        title: params[:title].to_s,
        raw: params[:raw].to_s,
      },
    }.to_json

    signature = DiscourseCustomWebhooks::Signature.sign(body, SiteSetting.custom_webhooks_secret)
    header = SiteSetting.custom_webhooks_signature_header.presence || "X-Discourse-Signature"

    response =
      DiscourseCustomWebhooks::Emitter
        .connection
        .post(url) do |req|
          req.headers["Content-Type"] = "application/json"
          req.headers[header] = signature
          req.body = body
        end

    verdict =
      begin
        JSON.parse(response.body)
      rescue StandardError
        {}
      end
    render json: normalize_verdict(verdict, event_id: event_id)
  rescue StandardError => e
    Rails.logger.warn("Custom webhooks moderation: text check failed: #{e.class} #{e.message}")
    render json: { can_publish: true }
  end

  # Records the author's response to the pre-publish text nudge (Edit or Post
  # anyway) — Khoros parity for `action=NUDGE_ACTION -> nudging-metrics/store`.
  # Analytics only: never blocks or alters composing, and failures are silent.
  def nudge_metric
    chosen_action = params[:nudge_action].to_s
    return render json: { status: "ignored" } if NUDGE_ACTIONS.exclude?(chosen_action)

    url = SiteSetting.custom_webhooks_nudge_metrics_url
    return render json: { status: "skipped" } if url.blank?

    body = {
      event_id: params[:event_id].to_s.presence || SecureRandom.uuid,
      source: "DISCOURSE",
      action: chosen_action,
      category: params[:category].presence,
      actor: {
        sso_id: sso_id_for(current_user&.id),
        locale: current_user&.effective_locale,
        trust_level: current_user&.trust_level,
      },
      recorded_at: Time.zone.now.iso8601,
    }.to_json

    signature = DiscourseCustomWebhooks::Signature.sign(body, SiteSetting.custom_webhooks_secret)
    header = SiteSetting.custom_webhooks_signature_header.presence || "X-Discourse-Signature"

    DiscourseCustomWebhooks::Emitter
      .connection
      .post(url) do |req|
        req.headers["Content-Type"] = "application/json"
        req.headers[header] = signature
        req.body = body
      end

    render json: { status: "recorded" }
  rescue StandardError => e
    Rails.logger.warn("Custom webhooks moderation: nudge metric failed: #{e.class} #{e.message}")
    render json: { status: "error" }
  end

  def callback
    payload = parse_body
    return render_json_error("invalid payload", status: 400) if payload.blank?

    event_id = payload["event_id"].presence || payload["moderation_id"].presence
    return render_json_error("missing event_id", status: 400) if event_id.blank?

    # Idempotency: a replayed verdict is a no-op.
    if already_processed?(event_id)
      return render json: { status: "noop", post_id: payload["post_id"] }
    end

    post = Post.with_deleted.find_by(id: payload["post_id"])
    return render_json_error("unknown post", status: 404) if post.blank?

    action = apply_verdict(post, payload)
    mark_processed(event_id)

    render json: { status: "applied", post_id: post.id, action: action }
  end

  private

  def ensure_enabled
    raise Discourse::NotFound unless SiteSetting.custom_webhooks_enabled
  end

  def verify_signature
    secret = SiteSetting.custom_webhooks_callback_secret
    provided = request.get_header(SIGNATURE_HEADER)
    unless DiscourseCustomWebhooks::Signature.valid?(request.raw_post, secret, provided)
      render_json_error("invalid signature", status: 401)
    end
  end

  def parse_body
    JSON.parse(request.raw_post)
  rescue JSON::ParserError
    nil
  end

  # Returns a short string describing what was done, for the response + log.
  def apply_verdict(post, payload)
    results = payload["results"] || {}
    image = results["image"] || {}
    text = results["text"] || {}

    csam = image["verdict"].to_s.upcase == "CSAM"
    text_violation = text["violation_found"] == true || text["can_publish"] == false
    moderation_id = payload["moderation_id"]

    if csam && post.topic&.private_message?
      # CSAM in a DM: keep hidden and route to staff review (abuse-queue parity).
      keep_hidden(post, reason: "custom_webhooks_moderation_csam_pm")
      raise_reviewable(post, category: "CSAM", moderation_id: moderation_id, details: image)
      "review"
    elsif csam
      # CSAM in a public post: removed automatically, no triage.
      destroy_post(post, reason: "custom_webhooks_moderation_csam")
      "destroyed"
    elsif text_violation
      # "Post anyway" text: the author already published past the composer nudge,
      # so the post is publicly visible. Match Khoros — the content STAYS visible
      # and is queued for a moderator (like player-reported/flagged content), who
      # decides whether to hide it. We only raise the review item here; we do not
      # newly hide a visible post. (A post that arrived hidden — e.g. a
      # hold-pending image — keeps whatever state it came in with.)
      flag_for_review(post, reason: "custom_webhooks_moderation_text_violation")
      raise_reviewable(
        post,
        category: text["category"],
        moderation_id: moderation_id,
        details: text,
      )
      "review"
    else
      publish(post)
      "published"
    end
  end

  # Builds the review-queue entry. The `details` hash carries the moderation
  # engine's output (subtype, severity, confidence, flagged terms, reasoning) so
  # the /review dashboard shows the full detail.
  def raise_reviewable(post, category:, moderation_id:, details: {})
    details ||= {}
    ReviewableCustomWebhooksModeration.needs_review!(
      target: post,
      topic: post.topic,
      created_by: Discourse.system_user,
      reviewable_by_moderator: true,
      payload: {
        "source" => "DISCOURSE",
        "category" => category,
        "moderation_id" => moderation_id,
        "subtype" => details["subtype"],
        "severity" => details["severity"],
        "confidence" => details["confidence"],
        "flagged_terms" => normalize_terms(details["flagged_terms"]),
        "reasoning" => details["reasoning"] || details["toxicity_reasoning"],
        "reasons" => Array(details["reasons"]).reject(&:blank?).presence,
      }.compact,
    )
  rescue StandardError => e
    Rails.logger.warn(
      "Custom webhooks moderation: could not create reviewable for post #{post.id}: #{e.message}",
    )
  end

  def publish(post)
    post.unhide! if post.hidden?
    log_action(post, "custom_webhooks_moderation_publish")
  end

  # The moderation engine may return flagged terms as an array or a single
  # comma-separated string; normalize to an array.
  def normalize_terms(terms)
    return nil if terms.blank?
    list = terms.is_a?(Array) ? terms : terms.to_s.split(",")
    list.map { |t| t.to_s.strip }.reject(&:blank?).presence
  end

  def keep_hidden(post, reason:)
    post.hide!(PostActionType.types[:inappropriate]) unless post.hidden?
    log_action(post, reason)
  end

  # Raises a review item without changing the post's visibility. Used for
  # "Post anyway" text violations, which stay publicly visible (Khoros parity)
  # until a moderator acts on the queued item.
  def flag_for_review(post, reason:)
    log_action(post, reason)
  end

  def destroy_post(post, reason:)
    post.hide!(PostActionType.types[:inappropriate]) unless post.hidden?
    unless post.deleted_at
      PostDestroyer.new(
        Discourse.system_user,
        post,
        context: "Custom webhooks moderation: #{reason}",
      ).destroy
    end
    log_action(post, reason)
  end

  def log_action(post, reason)
    StaffActionLogger.new(Discourse.system_user).log_custom(
      "custom_webhooks_moderation",
      post_id: post.id,
      topic_id: post.topic_id,
      reason: reason,
    )
  rescue StandardError => e
    Rails.logger.warn(
      "Custom webhooks moderation: audit log failed for post #{post.id}: #{e.message}",
    )
  end

  def processed_key(event_id)
    "custom_webhooks_moderation:processed:#{event_id}"
  end

  def already_processed?(event_id)
    Discourse.redis.get(processed_key(event_id)).present?
  end

  def mark_processed(event_id)
    Discourse.redis.setex(processed_key(event_id), PROCESSED_TTL.to_i, "1")
  end

  # Flattens the pipeline text response (which may be nested under "results.text"
  # or "response") into the small shape the composer nudge consumes.
  def normalize_verdict(verdict, event_id:)
    node = verdict["results"]&.dig("text") || verdict["response"] || verdict
    can_publish = node["can_publish"]
    can_publish = !(node["violation_found"] == true) if can_publish.nil?
    {
      can_publish: can_publish != false,
      nudge_message: node["nudge_message"] || node["nudgeMessage"],
      suggested_rewrite: node["suggested_rewrite"] || node["suggestedRewrite"],
      category: node["category"],
      event_id: event_id,
    }
  end

  def sso_id_for(user_id)
    return nil if user_id.blank?
    provider = SiteSetting.custom_webhooks_sso_provider
    return nil if provider.blank?
    UserAssociatedAccount.find_by(provider_name: provider, user_id: user_id)&.provider_uid
  end
end
