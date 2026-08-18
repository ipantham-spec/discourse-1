# frozen_string_literal: true

# Serializes a moderation reviewable for the /review dashboard. Surfaces the
# detail the moderation pipeline returns (category, subtype, severity,
# confidence, the flagged terms, and the model's reasoning) so the Discourse
# queue shows the full context.
class ReviewableCustomWebhooksModerationSerializer < ReviewableSerializer
  attributes :source,
             :category,
             :subtype,
             :severity,
             :confidence,
             :flagged_terms,
             :reasoning,
             :reasons,
             :moderation_id

  def source
    payload_value("source")
  end

  def category
    payload_value("category")
  end

  def subtype
    payload_value("subtype")
  end

  def severity
    payload_value("severity")
  end

  def confidence
    payload_value("confidence")
  end

  def flagged_terms
    Array(payload_value("flagged_terms")).reject(&:blank?)
  end

  def reasoning
    payload_value("reasoning")
  end

  def reasons
    Array(payload_value("reasons")).reject(&:blank?)
  end

  def moderation_id
    payload_value("moderation_id")
  end

  private

  def payload_value(key)
    object.payload&.dig(key)
  end
end
