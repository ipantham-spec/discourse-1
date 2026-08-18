# frozen_string_literal: true

require_dependency "reviewable"

# A review-queue entry raised when the moderation pipeline reports a violation
# that needs human triage (text violations, and CSAM in private messages). CSAM
# in public posts is handled automatically and does not create a reviewable.
#
# Moderators act on it in /review: keep it hidden (agree), publish it
# (disagree), delete, or ignore.
class ReviewableCustomWebhooksModeration < Reviewable
  def self.action_aliases
    { agree_and_keep: :agree_and_keep_hidden }
  end

  def build_actions(actions, guardian, _args)
    return actions if !pending? || post.blank?

    agree =
      actions.add_bundle("#{id}-agree", icon: "thumbs-up", label: "reviewables.actions.agree.title")
    build_action(actions, :agree_and_keep_hidden, icon: "far-eye-slash", bundle: agree)
    if guardian.can_delete_post_or_topic?(post)
      build_action(actions, :delete_and_agree, icon: "trash-can", bundle: agree)
    end

    build_action(actions, :disagree_and_publish, icon: "far-eye")
    build_action(actions, :ignore, icon: "xmark")

    actions
  end

  def perform_agree_and_keep_hidden(_performed_by, _args)
    post.hide!(PostActionType.types[:inappropriate]) unless post.hidden?
    agree
  end

  def perform_disagree_and_publish(performed_by, _args)
    if post.hidden?
      post.acting_user = performed_by
      post.unhide!
    end
    create_result(:success, :rejected)
  end

  def perform_ignore(_performed_by, _args)
    create_result(:success, :ignored)
  end

  def perform_delete_and_agree(performed_by, _args)
    PostDestroyer.new(performed_by, post, reviewable_id: id, context: "review").destroy
    agree
  end

  private

  def post
    @post ||= target || Post.with_deleted.find_by(id: target_id)
  end

  def agree
    create_result(:success, :approved) { |result| result.recalculate_score = true }
  end

  def build_action(actions, id, icon:, bundle: nil, button_class: nil)
    actions.add(id, bundle: bundle) do |action|
      action.icon = icon
      action.button_class = button_class
      action.label = "js.custom_webhooks.reviewable.actions.#{id}.title"
    end
  end
end
